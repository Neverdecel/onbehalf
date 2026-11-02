#!/usr/bin/env bash
# Route: an interface broker asks root for the route to the runtime of one
# user. The route goes only to a port where that user listens, because it
# contains the password of the service.
set -uo pipefail
. /src/test/lib.sh

listens() { as "$1" 'jq -r .port ~/.config/opencode/service.json'; }
for u in "${PEOPLE[@]}"; do as "$u" "opencode service start" >/dev/null 2>&1; done

# The route of alice opens her runtime, and only with its password.
route=$(onbehalf route alice 2>&1)
check "root gets the route of alice" test $? -eq 0
url=$(jq -r .url <<<"$route" 2>/dev/null)
check "the route goes to the port of alice" test "$url" = "http://127.0.0.1:$(listens alice)"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -u "opencode:$(jq -r .password <<<"$route")" "$url/api/session")
check "the route opens the runtime of alice (HTTP $code)" test "$code" = 200
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url/api/session")
check "the runtime refuses a request without the password (HTTP $code)" test "$code" = 401

check "a user cannot get a route" denied alice "onbehalf route alice"
check "there is no route for an account that is not a user" bash -c '! onbehalf route root >/dev/null 2>&1'

# alice sets the port of bob: the route must not send her password to bob.
port=$(listens alice)
as alice "opencode service stop" >/dev/null 2>&1
as alice "jq '.port = $(listens bob)' ~/.config/opencode/service.json >/tmp/svc.\$\$ && cat /tmp/svc.\$\$ >~/.config/opencode/service.json && rm /tmp/svc.\$\$"
out=$(onbehalf route alice 2>&1)
check "no route to a port where a different user listens" test $? -ne 0
grep -q 'different account' <<<"$out" || sed 's/^/        /' <<<"$out"
as alice "jq '.port = $port' ~/.config/opencode/service.json >/tmp/svc.\$\$ && cat /tmp/svc.\$\$ >~/.config/opencode/service.json && rm /tmp/svc.\$\$"

# A stopped runtime has no route.
out=$(onbehalf route alice 2>&1)
check "no route to a runtime that does not run" test $? -ne 0
grep -q 'does not run' <<<"$out" || sed 's/^/        /' <<<"$out"

# bob holds the port of alice while her runtime is stopped.
as bob "PORT=$port nohup node /src/test/fixtures/squat.js > /tmp/squat-route.log 2>&1 &"
for _ in $(seq 20); do
  grep -q listening /tmp/squat-route.log 2>/dev/null && break
  sleep 0.5
done
check "bob holds the port of alice (test setup)" grep -q listening /tmp/squat-route.log
out=$(onbehalf route alice 2>&1)
check "no route to the port of alice while bob holds it" test $? -ne 0
check "the output of the refused route has no password" bash -c '! grep -q password <<<"$1"' _ "$out"
pkill -u bob -f squat.js

# A link in the settings of alice cannot make root read a file of root.
printf '{"port": %s, "password": "root-secret"}\n' "$port" >/root/route-test.json
chmod 600 /root/route-test.json
as alice "mv ~/.config/opencode/service.json ~/.config/opencode/service.json.bak && ln -s /root/route-test.json ~/.config/opencode/service.json"
as alice "opencode service start" >/dev/null 2>&1
out=$(onbehalf route alice 2>&1)
check "a link to a file of root gives no secret of root" bash -c '! grep -q root-secret <<<"$1"' _ "$out"
as alice "rm ~/.config/opencode/service.json && mv ~/.config/opencode/service.json.bak ~/.config/opencode/service.json"
rm -f /root/route-test.json
as alice "opencode service restart" >/dev/null 2>&1
check "root gets the route of alice again" bash -c 'onbehalf route alice >/dev/null'

exit $FAILED
