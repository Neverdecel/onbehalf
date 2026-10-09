#!/usr/bin/env bash
# onbehalf health: the checks pass on a good host and name what breaks. The
# timer's run (health --record) posts to a webhook only when the problems
# change. The webhook URL stays root-only. The model probe uses its own key.
set -uo pipefail
. /src/test/lib.sh

# The disk of a test host can be anything: test the disk check on its own.
export HEALTH_DISK_WARN=101 HEALTH_DISK_FAIL=101
check "health warns about a full disk" \
  test "$(HEALTH_DISK_WARN=0 onbehalf health --json | jq -r '.checks[] | select(.id == "disk") | .status')" = warn

status_of() { jq -r --arg id "$1" '.checks[] | select(.id == $id) | .status' <<<"$2"; }

out=$(onbehalf health --json)
for id in gateway gateway-db admin-key stack keys provider; do
  check "health check '$id' passes on the test host" test "$(status_of "$id" "$out")" = ok
done
check "health has no model probe unless turned on" test -z "$(status_of probe "$out")"
check "a user cannot run onbehalf health" denied alice "onbehalf health"

# A local webhook that keeps every post, one JSON body per line.
hooks=$(mktemp)
start_hook() {
  node -e '
    require("http").createServer((q, s) => {
      let b = ""; q.on("data", c => b += c);
      q.on("end", () => { require("fs").appendFileSync(process.argv[1], b.replace(/\n/g, " ") + "\n"); s.end("ok"); });
    }).listen(8765, "127.0.0.1");' "$hooks" &
  hook_pid=$!
  for _ in $(seq 20); do
    curl -s -o /dev/null http://127.0.0.1:8765/ && break
    sleep 0.5
  done
  : >"$hooks"
}
start_hook
posts() { wc -l <"$hooks"; }

out=$(onbehalf health on --every 5 --webhook http://127.0.0.1:8765/hook 2>&1)
check "onbehalf health on succeeds" test $? -eq 0
check "the timer runs health --record" grep -q "ExecStart=.* health --record" /etc/systemd/system/onbehalf-health.service
check "the timer runs every 5 minutes" grep -q "OnUnitActiveSec=5min" /etc/systemd/system/onbehalf-health.timer
check "the webhook URL is readable by root only" test "$(stat -c '%a %U' /etc/onbehalf/health.conf)" = "600 root"
check "a user cannot read the webhook URL" denied alice "cat /etc/onbehalf/health.conf"

onbehalf health --record >/dev/null
check "a healthy first run posts nothing" test "$(posts)" = 0
check "the run is kept for doctor" test "$(jq -r .status /var/lib/onbehalf/health.json)" != fail

# Break the gateway address: the next run posts once, the one after not again.
cp /etc/onbehalf/onbehalf.conf /tmp/onbehalf.conf.bak
sed -i 's|^ONBEHALF_GATEWAY_URL=.*|ONBEHALF_GATEWAY_URL=http://127.0.0.1:9|' /etc/onbehalf/onbehalf.conf
out=$(onbehalf health 2>&1)
check "health fails when the gateway does not answer" test $? -ne 0
check "health names the gateway" grep -q "the gateway http://127.0.0.1:9 does not answer" <<<"$out"
onbehalf health --record >/dev/null 2>&1
check "a new problem posts one alert" test "$(posts)" = 1
check "the alert names the problem and its fix" \
  bash -c 'tail -1 "$1" | jq -e ".text | contains(\"does not answer\") and contains(\"fix:\")" >/dev/null' _ "$hooks"
onbehalf health --record >/dev/null 2>&1
check "the same problem does not post again" test "$(posts)" = 1
cp /tmp/onbehalf.conf.bak /etc/onbehalf/onbehalf.conf
onbehalf health --record >/dev/null 2>&1
check "recovery posts once" test "$(posts)" = 2
check "the recovery says all checks pass again" bash -c 'tail -1 "$1" | jq -e ".text | contains(\"all health checks pass again\")" >/dev/null' _ "$hooks"

# A webhook that fails: the alert is sent again at the next run.
kill "$hook_pid" 2>/dev/null
wait "$hook_pid" 2>/dev/null
sed -i 's|^ONBEHALF_GATEWAY_URL=.*|ONBEHALF_GATEWAY_URL=http://127.0.0.1:9|' /etc/onbehalf/onbehalf.conf
onbehalf health --record >/dev/null 2>&1
check "an alert that could not be posted is not marked as sent" \
  test "$(jq -c .alerted /var/lib/onbehalf/health.json)" = '[]'
cp /tmp/onbehalf.conf.bak /etc/onbehalf/onbehalf.conf
onbehalf health --record >/dev/null 2>&1

# Teams format: an adaptive card.
start_hook
onbehalf health on --format teams >/dev/null 2>&1
check "the webhook stays set when only the format changes" grep -q "127.0.0.1:8765" /etc/onbehalf/health.conf
check "health alert-test posts" bash -c 'onbehalf health alert-test >/dev/null 2>&1'
check "the Teams format is an adaptive card" \
  bash -c 'tail -1 "$1" | jq -e ".attachments[0].content.type == \"AdaptiveCard\"" >/dev/null' _ "$hooks"

# Provider failures from real requests: bob asks a model whose provider refuses.
for _ in 1 2 3; do
  curl -s -o /dev/null --max-time 20 "$ONBEHALF_GATEWAY_URL/v1/chat/completions" \
    -H @<(printf 'Authorization: Bearer %s\n' "$(</home/bob/.config/onbehalf/gateway.key)") \
    -H 'Content-Type: application/json' --data '{"model":"blocked-model","messages":[{"role":"user","content":"hi"}]}'
done
for _ in $(seq 60); do
  out=$(onbehalf health --json)
  [ "$(status_of provider "$out")" = fail ] && break
  sleep 2
done
check "health fails when the provider refuses recent requests" test "$(status_of provider "$out")" = fail
check "the provider check names the model" \
  bash -c 'jq -e ".checks[] | select(.id == \"provider\") | .text | contains(\"blocked-model\")" >/dev/null <<<"$1"' _ "$out"

# The probe: its own key, root only, and the report shows it apart.
out=$(onbehalf health on --probe 2>&1)
check "health on --probe creates the probe key" test "$(stat -c '%a %U' /etc/onbehalf/probe.key 2>/dev/null)" = "600 root"
out=$(onbehalf health --json)
check "the probe gets an answer from the model" test "$(status_of probe "$out")" = ok
for _ in $(seq 60); do
  r=$(onbehalf report --json)
  jq -e '.services[] | select(.name == "onbehalf-probe")' <<<"$r" >/dev/null && break
  sleep 2
done
check "the report shows the probe as a service" \
  test "$(jq '[.services[] | select(.name == "onbehalf-probe" and .requests > 0)] | length' <<<"$r")" = 1
check "the probe is no user" test "$(jq '[(.users, .past, .other)[] | select(.name == "onbehalf-probe")] | length' <<<"$r")" = 0
out=$(onbehalf report)
check "the readable report shows the probe under Service usage" \
  bash -c 'sed -n "/^Service usage/,/^Models/p" <<<"$1" | grep -q "onbehalf-probe (health probe)"' _ "$out"

out=$(onbehalf doctor 2>&1)
check "doctor shows that the health checks run" grep -q "health checks every 5 minutes" <<<"$out"

out=$(onbehalf health off 2>&1)
check "onbehalf health off succeeds" test $? -eq 0
check "health off removes the timer" test ! -e /etc/systemd/system/onbehalf-health.timer
check "health off revokes the probe key" test ! -e /etc/onbehalf/probe.key
check "doctor shows that the health checks are off" bash -c 'onbehalf doctor 2>&1 | grep -q "health checks are off"'

kill "$hook_pid" 2>/dev/null
rm -f "$hooks" /tmp/onbehalf.conf.bak /var/lib/onbehalf/health.json
exit $FAILED
