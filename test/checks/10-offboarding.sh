#!/usr/bin/env bash
# Offboarding (MVP step 10): remove bob while he is active. Afterwards nothing
# of bob is left on the host, his gateway key no longer works, and alice
# continues to work. Runs last, because it removes bob.
set -uo pipefail
. /src/test/lib.sh

uid=$(id -u bob)
bob_key=$(</home/bob/.config/onbehalf/gateway.key)

# Bob is active: agent service, a background job, a file in /tmp.
as bob "opencode service start" >/dev/null 2>&1
as bob "nohup bash -c 'sleep 600; :' >/dev/null 2>&1 &"
as bob "echo work > /tmp/bob-notes"
check "bob has running processes (test setup)" pgrep -u "$uid"

out=$(onbehalf user remove bob 2>&1)
check "onbehalf user remove bob succeeds" test $? -eq 0
sed 's/^/        /' <<<"$out"

check "bob's account is gone" bash -c '! id bob >/dev/null 2>&1'
check "no process of bob's uid runs" bash -c "! pgrep -u $uid"
check "bob's home directory is gone" test ! -e /home/bob
left=$(find / -xdev "${NOT_SRC[@]}" -uid "$uid" -print 2>/dev/null)
check "no file of bob's uid is left" test -z "$left"
[ -z "$left" ] || sed 's/^/        /' <<<"$left" | head -10

code=$(curl -s -o /dev/null -w '%{http_code}' "$ONBEHALF_GATEWAY_URL/v1/models" \
  -H @<(printf 'Authorization: Bearer %s\n' "$bob_key"))
check "bob's gateway key is revoked (HTTP $code)" grep -qxE '401|403' <<<"$code"

check "onbehalf records bob as a past user" test -f /var/lib/onbehalf/removed/bob
r=$(onbehalf report --json)
check "bob's past use stays in the report, as a past user" \
  test "$(jq '[.past[] | select(.name == "bob" and .requests > 0 and .removed != null)] | length' <<<"$r")" = 1
check "bob is no longer a current user" test "$(jq '[.users[] | select(.name == "bob")] | length' <<<"$r")" = 0
check "the adoption summary agrees with the current users" test "$(jq '.summary.users == (.users | length)' <<<"$r")" = true
check "the model totals include the use of past users" \
  test "$(jq '([.models[].requests] | add) == ([(.users, .past, .services, .other)[].requests] | add)' <<<"$r")" = true
out=$(onbehalf report 2>&1)
check "the readable report shows bob under Past users, not Current users" \
  bash -c 'sed -n "/^Past users/,/^Service usage/p" <<<"$1" | grep -q "^  bob " &&
    ! sed -n "/^Current users/,/^Past users/p" <<<"$1" | grep -q "^  bob "' _ "$out"

out=$(as alice "cd ~ && timeout 180 opencode run 'still here?'" 2>&1)
check "alice still works through the gateway" grep -q onbehalf-mock-ok <<<"$out"

out=$(onbehalf user remove bob 2>&1)
check "removing bob again is safe" test $? -eq 0

exit $FAILED
