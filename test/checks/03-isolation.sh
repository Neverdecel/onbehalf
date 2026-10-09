#!/usr/bin/env bash
# Isolation (MVP step 9): one user's agent cannot reach another user's
# files, processes or agent service. The agent is only a process of that
# user, so these are OS properties: a plain shell as the user tests them.
set -uo pipefail
. /src/test/lib.sh

for u in "${PEOPLE[@]}"; do as "$u" "opencode service start" >/dev/null 2>&1; done

# Listening TCP ports of a user. Read from /proc/net/tcp because ss does not
# show socket owners inside a rootless container. State 0A is LISTEN.
listen_ports() {
  local hex
  for hex in $(awk -v uid="$(id -u "$1")" 'NR > 1 && $4 == "0A" && $8 == uid { split($2, a, ":"); print a[2] }' /proc/net/tcp /proc/net/tcp6); do
    echo $((16#$hex))
  done | sort -un
}

for a in "${PEOPLE[@]}"; do
  for b in "${PEOPLE[@]}"; do
    [ "$a" = "$b" ] && continue

    # Files: nothing of a user is readable for another user.
    readable=$(as "$b" "find / -xdev ${NOT_SRC[*]} -user $a -readable -print 2>/dev/null")
    check "$b can read no file of $a" test -z "$readable"
    [ -z "$readable" ] || sed 's/^/        /' <<<"$readable" | head -10

    # Processes: no environment, no signals.
    pid=$(pgrep -u "$a" -o opencode)
    check "$a has a running opencode process" test -n "$pid"
    check "$b cannot read the environment of $a's processes" denied "$b" "cat /proc/$pid/environ"
    check "$b cannot signal $a's processes" denied "$b" "kill -0 $pid"

    # Services: every port of a user refuses the other user.
    ports=$(listen_ports "$a")
    check "$a has a listening port to probe" test -n "$ports"
    for p in $ports; do
      code=$(as "$b" "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:$p/api/session")
      check "$b gets no API access on $a's port $p (HTTP $code)" grep -qxE '000|401|403' <<<"$code"
    done
  done
done

for u in "${PEOPLE[@]}"; do
  check "$u cannot change the shared stack" denied "$u" "touch $ONBEHALF_STACK/current/opencode/x"
  check "$u cannot switch the current stack" denied "$u" "ln -sfn / $ONBEHALF_STACK/current"
  check "$u cannot read the gateway admin key" denied "$u" "cat /etc/onbehalf/gateway-admin.key"
done

# Port squatting: bob starts a fake service on alice's port before she does.
as alice "opencode service stop" >/dev/null 2>&1
port=$((ONBEHALF_PORT_BASE + $(id -u alice)))
for _ in $(seq 20); do
  [ -z "$(listen_ports alice)" ] && break
  sleep 0.5
done
as bob "PORT=$port nohup node /src/test/fixtures/squat.js > /tmp/squat.log 2>&1 &"
for _ in $(seq 20); do
  grep -q listening /tmp/squat.log 2>/dev/null && break
  sleep 0.5
done
check "bob holds alice's service port (test setup)" grep -q listening /tmp/squat.log

out=$(as alice "cd ~ && timeout 60 opencode run 'squat test'" 2>&1)
check "a squatter on alice's port receives no request from her" bash -c '! grep -q ^request /tmp/squat.log'
grep ^request /tmp/squat.log | cut -c1-300 | sed 's/^/        /'
known "alice can work while bob holds her service port (denial of service)" grep -q onbehalf-mock-ok <<<"$out"
pkill -u bob -f squat.js

exit $FAILED
