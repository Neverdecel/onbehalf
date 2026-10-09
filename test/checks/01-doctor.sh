#!/usr/bin/env bash
# Operator and user tools: onbehalf doctor and onbehalf status pass on a
# good host, and doctor finds problems that break the core claim.
set -uo pipefail
. /src/test/lib.sh

out=$(onbehalf doctor 2>&1)
check "onbehalf doctor passes on the test host" test $? -eq 0
grep -E '✗|failed' <<<"$out" | sed 's/^/        /'
check "doctor checks every user" bash -c 'grep -q "^alice" <<<"$1" && grep -q "^bob" <<<"$1"' _ "$out"

out=$(as alice "onbehalf status" 2>&1)
check "onbehalf status passes for alice" test $? -eq 0
grep -E '✗|failed' <<<"$out" | sed 's/^/        /'
check "status shows that alice's gateway key works" grep -q "your gateway key works" <<<"$out"
check "status shows alice's Git identity" grep -q "Git: alice <alice@onbehalf.test>" <<<"$out"

# A user repairs their own setup with the fixes from status, without root.
port=$((ONBEHALF_PORT_BASE + $(id -u alice)))
as alice 'jq "del(.port)" ~/.config/opencode/service.json >/tmp/svc.$$ && mv /tmp/svc.$$ ~/.config/opencode/service.json'
out=$(as alice "onbehalf status" 2>&1)
check "status fails when alice's service port is the shared default" test $? -ne 0
check "status gives alice a port fix without root" grep -q "fix: opencode service set port $port" <<<"$out"
as alice "opencode service set port $((port + 1))" >/dev/null
check "a personal port of alice's choice passes status" bash -c 'runuser -l alice -c "onbehalf status" >/dev/null 2>&1 </dev/null'
as alice "opencode service set port $port" >/dev/null
as alice 'rm ~/.config/opencode/opencode.json'
out=$(as alice "onbehalf status" 2>&1)
check "status gives alice a link fix without root" grep -q "fix: ln -sfn $ONBEHALF_STACK/current/opencode/opencode.json" <<<"$out"
as alice "ln -sfn $ONBEHALF_STACK/current/opencode/opencode.json ~/.config/opencode/opencode.json"
check "status passes after alice's own fixes" bash -c 'runuser -l alice -c "onbehalf status" >/dev/null 2>&1 </dev/null'

check "onbehalf status refuses to run as root" bash -c '! onbehalf status >/dev/null 2>&1'
check "operator commands refuse to run as a user" denied alice "onbehalf user add mallory"

# Problems on purpose; doctor must fail and name each one.
key=/home/alice/.config/onbehalf/gateway.key
chmod 644 "$key"
out=$(onbehalf doctor 2>&1)
check "doctor fails when a gateway key is readable by others" test $? -ne 0
check "doctor names the readable gateway key" grep -q "gateway key has the wrong owner or mode" <<<"$out"
chmod 600 "$key"

groupadd -f docker && gpasswd -a bob docker >/dev/null
out=$(onbehalf doctor 2>&1)
check "doctor fails when a user is in the docker group" test $? -ne 0
check "doctor explains the docker group" grep -q "bob is in the group(s) docker, so bob can act as other users" <<<"$out"
gpasswd -d bob docker >/dev/null

check "doctor passes again after the fixes" bash -c 'onbehalf doctor >/dev/null 2>&1'

out=$(/src/install.sh 2>&1)
check "running the installer again is safe" test $? -eq 0
check "the installer sees that the host is set up" grep -q "already set up" <<<"$out"

exit $FAILED
