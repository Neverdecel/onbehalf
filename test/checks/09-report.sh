#!/usr/bin/env bash
# onbehalf report: the operator sees who uses the agents, how much, and which
# requests fail, per user and per model. Never what a user asked: the
# test gateway stores prompts on purpose, and the report must not show them.
set -uo pipefail
. /src/test/lib.sh

secret="report-secret-$RANDOM$RANDOM"
ask() {
  curl -s --max-time 20 -o /dev/null -w '%{http_code}' "$ONBEHALF_GATEWAY_URL/v1/chat/completions" \
    -H @<(printf 'Authorization: Bearer %s\n' "$(<"/home/$1/.config/onbehalf/gateway.key")") \
    -H 'Content-Type: application/json' \
    --data "{\"model\":\"$2\",\"messages\":[{\"role\":\"user\",\"content\":\"$secret\"}]}"
}
before=$(onbehalf report --json | jq '[.users[] | {(.name): .}] | add')
check "alice's requests go through (test setup)" test "$(ask alice mock-model)$(ask alice mock-model)" = 200200
check "bob's request to a refusing provider fails (test setup)" test "$(ask bob blocked-model)" = 403

# The gateway writes its spend logs in batches.
for _ in $(seq 60); do
  r=$(onbehalf report --json)
  [ "$(jq '.errors | map(select(.user == "bob" and .model == "blocked-model")) | length' <<<"$r")" != 0 ] \
    && [ "$(jq '.users[] | select(.name == "alice") | .requests' <<<"$r")" -ge "$(($(jq '.alice.requests' <<<"$before") + 2))" ] \
    && break
  sleep 2
done

p() { jq --arg u "$1" ".users[] | select(.name == \$u) | $2" <<<"$r"; }
check "the report lists every user" test "$(jq -c '[.users[].name] | sort' <<<"$r")" = '["alice","bob"]'
check "alice's two requests count" test "$(p alice .requests)" -ge "$(($(jq '.alice.requests' <<<"$before") + 2))"
check "alice's requests count tokens and spend" bash -c '[ "$1" -gt 0 ] && [ "$2" = true ]' _ "$(p alice .tokens)" "$(p alice '.spend > 0')"
check "bob's refused request counts as failed" test "$(p bob .failed)" -ge 1
check "the report shows when each user joined" test "$(p alice '.joined != null')" = true
check "the report shows each user's last model request" test "$(p alice '.last_request != null')" = true
check "the report counts each user's work tools" test "$(p alice '.tools.total > 0')" = true
check "mock-model appears with its users" \
  test "$(jq '.models[] | select(.model == "mock-model") | .users >= 1' <<<"$r")" = true
check "the refusal names user, model and provider message" \
  test "$(jq '[.errors[] | select(.user == "bob" and .model == "blocked-model" and (.message | contains("Public access is disabled")))] | length' <<<"$r")" = 1
check "the adoption summary counts both users" test "$(jq .summary.users <<<"$r")" = 2

out=$(onbehalf report 2>&1)
check "the readable report passes" test $? -eq 0
for want in Adoption "Current users" "Past users" "Service usage" Models "Failed requests" "bob · blocked-model"; do
  check "the readable report shows '$want'" grep -qF "$want" <<<"$out"
done
# runuser leaves no login record, and the start of the login records
# ("wtmp begins") is no login.
check "users who never logged in have no last login" \
  test "$(jq -c '[.users[] | select(.last_login == null) | .name]' <<<"$r")" = '["alice","bob"]'
check "the report names users without a login record" grep -q "no login recorded: alice, bob" <<<"$out"
touch -d '2026-01-02 03:04:05 UTC' /home/alice/.config/onbehalf/last-login
check "the login mark of onbehalf login is the last login" \
  test "$(onbehalf report --json | jq -r '.users[] | select(.name == "alice") | .last_login')" = 2026-01-02T03:04:05Z
rm -f /home/alice/.config/onbehalf/last-login
check "no report shows what a user asked" bash -c '! grep -qF "$1" <<<"$2$3"' _ "$secret" "$out" "$r"
check "no report shows the provider key" bash -c '! grep -qF "$ONBEHALF_CANARY" <<<"$1$2"' _ "$out" "$r"

out=$(onbehalf doctor 2>&1)
check "doctor warns that the gateway stores prompts" \
  grep -q "the gateway keeps the questions of users and the answers of the model" <<<"$out"

# Each user sees their own model use in status, read with their own key.
for _ in $(seq 30); do
  out=$(as alice "onbehalf status" 2>&1)
  n=$(sed -n 's/.*last 7 days: \([0-9]*\) requests.*/\1/p' <<<"$out")
  [ "${n:-0}" -ge 2 ] && break
  sleep 2
done
check "status shows alice her own model use" test "${n:-0}" -ge 2
check "status shows the last 30 days too" grep -q "last 30 days: [0-9]* requests" <<<"$out"
own() {
  curl -s -o /dev/null -w '%{http_code}' "$ONBEHALF_GATEWAY_URL$2" \
    -H @<(printf 'Authorization: Bearer %s\n' "$(<"/home/$1/.config/onbehalf/gateway.key")")
}
check "alice's key cannot read bob's model use" test "$(own alice '/user/daily/activity?start_date=2026-01-01&end_date=2099-01-01&user_id=bob')" = 403
check "alice's key cannot read the spend logs" grep -qxE '401|403' <<<"$(own alice /spend/logs)"

# A key from an older onbehalf lacks the usage route: doctor warns, status
# explains, and a stack install without restart repairs every key.
token=$(sha256sum /home/bob/.config/onbehalf/gateway.key | cut -d' ' -f1)
old='["/models","/v1/models","/chat/completions","/v1/chat/completions","/responses","/v1/responses","/messages","/v1/messages"]'
admin_post() {
  curl -fsS "$ONBEHALF_GATEWAY_URL$1" -H 'Content-Type: application/json' --data "$2" \
    -H @<(printf 'Authorization: Bearer %s\n' "$(</etc/onbehalf/gateway-admin.key)")
}
admin_post /key/update "{\"key\":\"$token\",\"allowed_routes\":$old}" >/dev/null
out=$(onbehalf doctor 2>&1)
check "doctor warns about a key with old routes, not an error" \
  bash -c 'grep -q "the gateway key of bob has the routes of an older onbehalf" <<<"$1" && ! grep -q "✗.*gateway key policy" <<<"$1"' _ "$out"
check "status tells bob why his model use is missing" \
  bash -c 'runuser -l bob -c "onbehalf status" </dev/null 2>&1 | grep -q "your gateway key cannot read your model use yet"'
as bob "opencode service start" >/dev/null 2>&1
pid=$(pgrep -u bob -f 'serve --service' | head -1)
check "bob's agent service runs (test setup)" test -n "$pid"
onbehalf stack install --no-restart /src/test/stack >/dev/null
check "stack install --no-restart gives bob's key the new routes" \
  bash -c '! onbehalf doctor 2>&1 | grep -q "routes of an older onbehalf"'
check "bob sees his model use again" bash -c 'runuser -l bob -c "onbehalf status" </dev/null 2>&1 | grep -q "last 7 days: [0-9]* requests"'
check "the repair restarted nothing" test "$(pgrep -u bob -f 'serve --service' | head -1)" = "$pid"

# Other users of the gateway: a service that the operator names, and a name
# that onbehalf does not know. Neither is a user.
key_of() {
  admin_post /key/generate "$(jq -nc --arg u "$1" '{user_id: $u, key_alias: "\($u)-test", models: ["mock-model"]}')" | jq -r .key
}
ask_as() {
  curl -s --max-time 20 -o /dev/null -w '%{http_code}' "$ONBEHALF_GATEWAY_URL/v1/chat/completions" \
    -H @<(printf 'Authorization: Bearer %s\n' "$1") -H 'Content-Type: application/json' \
    --data '{"model":"mock-model","messages":[{"role":"user","content":"ping"}]}'
}
svc_key=$(key_of memory-service)
other_key=$(key_of batch-job)
check "the service and the unknown name send requests (test setup)" \
  test "$(ask_as "$svc_key")$(ask_as "$other_key")" = 200200
printf '# Services of this host\nmemory-service\n' >/etc/onbehalf/report-services
for _ in $(seq 60); do
  r=$(onbehalf report --json)
  [ "$(jq '[.services[].name, .other[].name] | map(select(. == "memory-service" or . == "batch-job")) | length' <<<"$r")" = 2 ] && break
  sleep 2
done
check "a named service is under services" test "$(jq '[.services[] | select(.name == "memory-service" and .requests > 0)] | length' <<<"$r")" = 1
check "an unknown name is under other, not past users" \
  test "$(jq '[.other[] | select(.name == "batch-job")] | length' <<<"$r"):$(jq '[.past[] | select(.name == "batch-job")] | length' <<<"$r")" = 1:0
check "the current users are only users" test "$(jq -c '[.users[].name] | sort' <<<"$r")" = '["alice","bob"]'
check "the adoption summary agrees with the current users" test "$(jq '.summary.users == (.users | length)' <<<"$r")" = true
check "the model totals include all use" \
  test "$(jq '([.models[].requests] | add) == ([(.users, .past, .services, .other)[].requests] | add)' <<<"$r")" = true
out=$(onbehalf report 2>&1)
check "the readable report shows memory-service under Service usage" \
  bash -c 'sed -n "/^Service usage/,/^Other usage/p" <<<"$1" | grep -q "^  memory-service "' _ "$out"
check "the readable report shows batch-job under Other usage" \
  bash -c 'sed -n "/^Other usage/,/^Models/p" <<<"$1" | grep -q "^  batch-job "' _ "$out"
check "the readable report has no Users table that mixes them" bash -c '! grep -qx "Users" <<<"$1"' _ "$out"
rm -f /etc/onbehalf/report-services
admin_post /key/delete "$(jq -nc --arg a "$svc_key" --arg b "$other_key" '{keys: [$a, $b]}')" >/dev/null

check "onbehalf report --days 1 works" bash -c 'onbehalf report --days 1 --json | jq -e ".window.days == 1" >/dev/null'
check "onbehalf report refuses a wrong period" bash -c '! onbehalf report --days 0 >/dev/null 2>&1'
check "a user cannot run onbehalf report" denied alice "onbehalf report"
out=$(as alice "onbehalf tools --list" 2>&1)
check "a user lists their work tools without a terminal" grep -qE $'^git\t(ok|todo|warn|missing)$' <<<"$out"

exit $FAILED
