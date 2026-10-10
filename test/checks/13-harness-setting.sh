#!/usr/bin/env bash
# The operator selects one AI harness for the host. onbehalf checks that the
# model gateway serves the API of that AI harness, without a model request.
set -uo pipefail
. /src/test/lib.sh

conf=/etc/onbehalf/onbehalf.conf
check "init writes the default AI harness" grep -qx 'ONBEHALF_HARNESS=opencode' "$conf"

before=$(sha256sum "$conf")
out=$(onbehalf init --harness nothere </dev/null 2>&1)
check "init refuses an AI harness that onbehalf does not support" grep -q "the AI harness must be one of: opencode claude" <<<"$out"
check "the refused init keeps the configuration" test "$(sha256sum "$conf")" = "$before"

# init again, without --harness: the host keeps its AI harness.
out=$(onbehalf init --gateway-url "$ONBEHALF_GATEWAY_URL" </etc/onbehalf/gateway-admin.key 2>&1)
check "init again succeeds" test $? -eq 0
check "init checks the API of the AI harness" grep -q "the gateway serves the API of OpenCode" <<<"$out"
check "init again keeps the AI harness" grep -qx 'ONBEHALF_HARNESS=opencode' "$conf"

out=$(onbehalf doctor 2>&1)
check "doctor checks the API of the AI harness" grep -q "the gateway serves the API of OpenCode" <<<"$out"
check "health checks the API of the AI harness" \
  test "$(onbehalf health --json | jq -r '.checks[] | select(.id == "gateway-api") | .status')" = ok

# A server without the routes: the check finds them, and sends no model request.
missing=$(ONBEHALF_GATEWAY_URL=$FORGEJO_URL bash -c '
  ONBEHALF_LIB=/src/lib/onbehalf
  for f in common ui harness harness-opencode; do . "$ONBEHALF_LIB/$f.sh"; done
  gateway_api_missing')
check "the API check finds a route that the gateway does not serve" test "$missing" = /v1/chat/completions

# A configuration with an AI harness that onbehalf does not support.
cp -p "$conf" "$conf.orig"
sed -i 's/^ONBEHALF_HARNESS=.*/ONBEHALF_HARNESS=nothere/' "$conf"
out=$(onbehalf doctor 2>&1)
check "doctor names an AI harness in the configuration that onbehalf does not support" \
  grep -q "the AI harness 'nothere' in /etc/onbehalf/onbehalf.conf is not one of: opencode claude" <<<"$out"
mv "$conf.orig" "$conf"

exit $FAILED
