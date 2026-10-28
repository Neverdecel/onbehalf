#!/usr/bin/env bash
# onbehalf supports only OpenCode. onbehalf checks that the model gateway
# serves the API of OpenCode, without a model request.
set -uo pipefail
. /src/test/lib.sh

conf=/etc/onbehalf/onbehalf.conf
check "init writes no AI harness setting" bash -c "! grep -q '^ONBEHALF_HARNESS=' $conf"

out=$(onbehalf init --harness opencode </dev/null 2>&1)
check "init refuses the old --harness option" grep -q "unknown option: --harness" <<<"$out"

out=$(onbehalf init --gateway-url "$ONBEHALF_GATEWAY_URL" </etc/onbehalf/gateway-admin.key 2>&1)
check "init again succeeds" test $? -eq 0
check "init checks the API of OpenCode" grep -q "the gateway serves the API of OpenCode" <<<"$out"

out=$(onbehalf doctor 2>&1)
check "doctor checks the API of OpenCode" grep -q "the gateway serves the API of OpenCode" <<<"$out"
check "health checks the API of OpenCode" \
  test "$(onbehalf health --json | jq -r '.checks[] | select(.id == "gateway-api") | .status')" = ok

# A server without the routes: the check finds them, and sends no model request.
missing=$(ONBEHALF_GATEWAY_URL=$FORGEJO_URL bash -c '
  ONBEHALF_LIB=/src/lib/onbehalf
  for f in common ui harness harness-opencode; do . "$ONBEHALF_LIB/$f.sh"; done
  gateway_api_missing')
check "the API check finds a route that the gateway does not serve" test "$missing" = /v1/chat/completions

# A host configuration of onbehalf 0.2 with Claude Code.
cp -p "$conf" "$conf.orig"
echo ONBEHALF_HARNESS=claude >>"$conf"
out=$(onbehalf doctor 2>&1)
check "doctor says that onbehalf supports only OpenCode" \
  grep -q "onbehalf supports only OpenCode. /etc/onbehalf/onbehalf.conf sets ONBEHALF_HARNESS=claude" <<<"$out"
mv "$conf.orig" "$conf"

exit $FAILED
