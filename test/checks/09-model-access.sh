#!/usr/bin/env bash
# Host configuration and model access are separate results. The gateway can
# answer and accept every key while the provider refuses every request.
# blocked-model is curated, but its provider answers 403 (fake-model/server.js).
set -uo pipefail
. /src/test/lib.sh

out=$(onbehalf doctor 2>&1)
check "doctor sends no model request without --model-check" grep -q "model access: not checked" <<<"$out"

out=$(onbehalf doctor --model-check 2>&1)
check "doctor --model-check passes on the test host" test $? -eq 0
grep -E '✗' <<<"$out" | sed 's/^/        /'
check "the model check uses the key of the first user" grep -q "one request to mock-model as alice" <<<"$out"
check "doctor reports that the model answered" grep -q "model access: the model answered" <<<"$out"

out=$(onbehalf doctor --user bob --model blocked-model 2>&1)
check "doctor fails when the provider refuses requests" test $? -ne 0
check "the host configuration still passes on its own" grep -q "host configuration: no errors" <<<"$out"
check "model access fails as a separate result" grep -q "model access: the model did not answer" <<<"$out"
check "doctor names the provider and shows its message" \
  grep -q "the model provider refused the request (HTTP 403): Public access is disabled" <<<"$out"
check "the fix points to the network rules of the provider" grep -q "network rules and the key of the provider" <<<"$out"

out=$(onbehalf doctor --model private-model 2>&1)
check "a model outside the catalog is a gateway refusal, not a provider one" \
  grep -q "the gateway refused the request (HTTP 403)" <<<"$out"
out=$(onbehalf doctor --user nobody 2>&1)
check "doctor refuses to check as an account that is not a user" grep -q "nobody is not a user on this host" <<<"$out"

out=$(as alice "onbehalf status --model-check" 2>&1)
check "a user checks their own model access" test $? -eq 0
check "status shows that the model answered" grep -q "mock-model answered" <<<"$out"
out=$(as alice "onbehalf status --model blocked-model" 2>&1)
check "status fails when the provider refuses requests" test $? -ne 0
check "status names the provider refusal" grep -q "the model provider refused the request (HTTP 403)" <<<"$out"
check "no output shows the provider key" bash -c '! grep -qF "$ONBEHALF_CANARY" <<<"$1"' _ "$out"

# onbehalf init: wrong URLs and keys change nothing, and the output says what to do next.
saved() { sha256sum /etc/onbehalf/onbehalf.conf /etc/onbehalf/gateway-admin.key; }
before=$(saved)
out=$(printf %s "$LITELLM_MASTER_KEY" | onbehalf init --gateway-url https://team.openai.azure.com/ 2>&1)
check "init refuses an Azure AI Foundry endpoint as gateway URL" test $? -ne 0
check "init explains the provider endpoint" grep -q "is an Azure AI Foundry endpoint, not the gateway" <<<"$out"
out=$(printf %s "$LITELLM_MASTER_KEY" | onbehalf init --gateway-url http://127.0.0.1:9 2>&1)
check "init stops when the gateway does not answer" test $? -ne 0
check "init shows how to set up the gateway" grep -q "examples/gateway" <<<"$out"
check "init shows how to continue" grep -q "sudo onbehalf init --gateway-url http://127.0.0.1:9" <<<"$out"
out=$(printf 'sk-not-the-master-key' | onbehalf init --gateway-url "$ONBEHALF_GATEWAY_URL" 2>&1)
check "init refuses a wrong admin key" test $? -ne 0
check "init says the admin key is not a provider key" grep -q "not a model provider key" <<<"$out"
check "failed init runs change nothing" test "$(saved)" = "$before"

# Interactive: a provider URL is explained and asked again. The key is not shown.
out=$(printf 'https://team.services.ai.azure.com\n%s\n%s\n' "$ONBEHALF_GATEWAY_URL" "$LITELLM_MASTER_KEY" \
  | timeout 30 script -qef -E never -c 'onbehalf init' /dev/null 2>&1)
check "interactive init succeeds after a corrected URL" test $? -eq 0
check "interactive init explains the gateway URL before it asks" grep -q "not the endpoint of the model provider" <<<"$out"
check "interactive init asks again after a provider URL" grep -q "is an Azure AI Foundry endpoint" <<<"$out"
check "interactive init does not show the admin key" bash -c '! grep -qF "$LITELLM_MASTER_KEY" <<<"$1"' _ "$out"

# Repeat setup: the same gateway (also as an OpenAI base URL) gives the same configuration.
out=$(printf %s "$LITELLM_MASTER_KEY" | onbehalf init --gateway-url "$ONBEHALF_GATEWAY_URL/v1/" 2>&1)
check "init runs again on a set-up host" test $? -eq 0
check "repeat init keeps the configuration" test "$(saved)" = "$before"
check "doctor passes after repeat init" bash -c 'onbehalf doctor >/dev/null 2>&1'

exit $FAILED
