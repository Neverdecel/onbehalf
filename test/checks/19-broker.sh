#!/usr/bin/env bash
# Broker: the example broker of examples/broker sends the login of the
# reverse proxy to the runtime of that user only. The test is the client of
# the reverse proxy: it connects to the socket of the broker and sets the
# login header, as the reverse proxy does after the single sign-on.
set -uo pipefail
. /src/test/lib.sh

MAP=/etc/onbehalf/entra.map
SOCK=/run/onbehalf-broker/broker.sock
LOG=/tmp/broker-$$.log
OID=0c0c0c0c-0000-4000-8000-00000000c0c0

# 10-offboarding removed bob. carol is the user of this check.
useradd -m -s /bin/bash carol
onbehalf user add carol >/dev/null 2>&1
printf 'carol %s Carol.Smith@corp.test\n' "$OID" >>"$MAP"
chmod 0644 "$MAP"
as carol "opencode service start" >/dev/null 2>&1

# The set up of the README: an account, one sudo rule and a socket directory.
useradd -r -M -s /bin/false onbehalf-broker
OB=$(command -v onbehalf)
echo "onbehalf-broker ALL=(root) NOPASSWD: $OB route --upn *" >/etc/sudoers.d/onbehalf-broker
chmod 0440 /etc/sudoers.d/onbehalf-broker
install -d -m 0750 -o onbehalf-broker -g onbehalf-broker /run/onbehalf-broker
runuser -u onbehalf-broker -- env BROKER_ROUTE="sudo -n $OB route --upn" \
  node /src/examples/broker/broker.js >"$LOG" 2>&1 &
BROKER=$!
for _ in $(seq 20); do
  [ -S "$SOCK" ] && break
  sleep 0.5
done
check "the broker listens on its socket (test setup)" test -S "$SOCK"

# get LOGIN PATH: the HTTP code of a request through the broker.
get() {
  curl -s -o /tmp/broker-body.$$ -w '%{http_code}' --max-time 10 --unix-socket "$SOCK" \
    ${1:+-H "x-auth-request-preferred-username: $1"} "http://board$2"
}

code=$(get carol.smith@corp.test /api/session)
check "the login of carol opens the runtime of carol (HTTP $code)" test "$code" = 200
check "the broker gives the sessions of carol as JSON" bash -c "jq -e .data /tmp/broker-body.$$ >/dev/null"
check "the broker sends the request to the port of carol" grep -q "carol GET /api/session 200" "$LOG"
code=$(get "" /api/session)
check "a request without a login is refused (HTTP $code)" test "$code" = 401
code=$(get erin@corp.test /api/session)
check "a login that is not linked to a user is refused (HTTP $code)" test "$code" = 403
code=$(get carol /api/session)
check "an account name is not a login (HTTP $code)" test "$code" = 403

# The client cannot select the password or the user.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --unix-socket "$SOCK" \
  -u opencode:wrong -H "x-auth-request-preferred-username: carol.smith@corp.test" http://board/api/session)
check "a password of the client does not change the route (HTTP $code)" test "$code" = 200
pw=$(as carol 'jq -r .password ~/.config/opencode/service.json')
check "carol has a service password (test setup)" test -n "$pw"
check "the broker writes no password to its log" bash -c '! grep -qF -- "$1" "$2"' _ "$pw" "$LOG"

check "a user cannot connect to the broker" denied alice "curl -s --max-time 5 --unix-socket $SOCK http://board/"
check "the broker account cannot get a route for a name" \
  bash -c "! runuser -u onbehalf-broker -- sudo -n $OB route carol >/dev/null 2>&1"

as carol "opencode service stop" >/dev/null 2>&1
code=$(get carol.smith@corp.test /api/session)
check "a runtime that does not run gives HTTP 503 (HTTP $code)" test "$code" = 503
check "the broker logs why it refused" grep -q "does not run" "$LOG"

kill "$BROKER" 2>/dev/null
pkill -u onbehalf-broker 2>/dev/null
rm -rf /run/onbehalf-broker /etc/sudoers.d/onbehalf-broker "$LOG" /tmp/broker-body.$$
userdel onbehalf-broker 2>/dev/null
onbehalf user remove carol >/dev/null 2>&1
sed -i '/^carol /d' "$MAP"
check "carol is removed (test cleanup)" bash -c '! id carol' 2>/dev/null

exit $FAILED
