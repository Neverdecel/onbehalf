#!/usr/bin/env bash
# Native overrides, named baseline items and gateway-enforced model curation.
set -uo pipefail
. /src/test/lib.sh

answer() { as "$1" "cd ~ && timeout 180 opencode run 'which model?'" 2>&1 | grep -o 'onbehalf-mock-[a-z0-9]*' | head -1; }
request() {
  local u=$1 path=$2 body=${3:-} method=GET
  [ -z "$body" ] || method=POST
  curl -s --max-time 20 -o /dev/null -w '%{http_code}' -X "$method" "$ONBEHALF_GATEWAY_URL$path" \
    -H @<(printf 'Authorization: Bearer %s\n' "$(<"/home/$u/.config/onbehalf/gateway.key")") \
    -H 'Content-Type: application/json' ${body:+--data "$body"}
}
access_denied() { [ "$1" = 401 ] || [ "$1" = 403 ]; }
for u in "${PEOPLE[@]}"; do
  models=$(curl -fsS "$ONBEHALF_GATEWAY_URL/v1/models" \
    -H @<(printf 'Authorization: Bearer %s\n' "$(<"/home/$u/.config/onbehalf/gateway.key")") | jq -r '.data[].id')
  check "$u cannot see a non-curated gateway model" bash -c '! grep -qx private-model <<<"$1"' _ "$models"
  code=$(request "$u" /v1/chat/completions '{"model":"private-model","messages":[{"role":"user","content":"hi"}]}')
  check "$u cannot call a non-curated model directly ($code)" test "$code" = 403
  token=$(sha256sum "/home/$u/.config/onbehalf/gateway.key" | cut -d' ' -f1)
  code=$(request "$u" /key/update "{\"key\":\"$token\",\"models\":[\"private-model\"]}")
  check "$u cannot expand their gateway key access ($code)" access_denied "$code"
  code=$(request "$u" /key/generate '{"models":["private-model"]}')
  check "$u cannot create an unrestricted replacement key ($code)" access_denied "$code"
done

as alice 'printf "%s\n" "{ // personal default" "  \"model\": \"onbehalf/mock-model-v2\"," "}" > ~/.config/opencode/opencode.jsonc'
as alice "opencode service restart" >/dev/null
check "alice selects a curated personal default" test "$(answer alice)" = onbehalf-mock-v2
check "bob keeps the shared default" test "$(answer bob)" = onbehalf-mock-ok

# A personal named agent does not hide other shared agents.
as alice 'printf "%s\n" "---" "description: Personal probe override" "mode: primary" "---" "Personal instructions." > ~/.config/opencode/agents/personal-probe.md'
as alice 'rm ~/.config/opencode/agents/onbehalf-probe.md && cp ~/.config/opencode/agents/personal-probe.md ~/.config/opencode/agents/onbehalf-probe.md'
override=$(sha256sum /home/alice/.config/opencode/opencode.jsonc)
agent=$(sha256sum /home/alice/.config/opencode/agents/onbehalf-probe.md)
key=$(sha256sum /home/alice/.config/onbehalf/gateway.key)
onbehalf user add alice >/dev/null
check "repeat onboarding keeps the personal default" test "$(sha256sum /home/alice/.config/opencode/opencode.jsonc)" = "$override"
v1=$(readlink "$ONBEHALF_STACK/current")
v2=$(mktemp -d)
cp -R /src/test/stack/. "$v2"
jq '.model = "onbehalf/mock-model-v2"' /src/test/stack/opencode/opencode.json >"$v2/opencode/opencode.json"
cp /src/test/stack/opencode/agents/onbehalf-probe.md "$v2/opencode/agents/another-shared-probe.md"
onbehalf stack install "$v2" >/dev/null
check "stack update keeps alice's override bytes" test "$(sha256sum /home/alice/.config/opencode/opencode.jsonc)" = "$override"
check "stack update keeps alice's gateway key" test "$(sha256sum /home/alice/.config/onbehalf/gateway.key)" = "$key"
check "bob receives the updated default" test "$(answer bob)" = onbehalf-mock-v2
# A restarted V2 service initializes location agents on its first request.
check "alice keeps her override after the service restarts" test "$(answer alice)" = onbehalf-mock-v2
out=$(as alice 'opencode debug agents')
if ! grep -q personal-probe <<<"$out"; then printf '%s\n' "$out" | sed 's/^/        /'; fi
check "alice retains her personal named agent" grep -q personal-probe <<<"$out"
check "alice also retains the shared named agent" grep -q onbehalf-probe <<<"$out"
check "alice receives an unshadowed new shared agent" grep -q another-shared-probe <<<"$out"
check "stack update preserves the same-name personal agent" test "$(sha256sum /home/alice/.config/opencode/agents/onbehalf-probe.md)" = "$agent"

onbehalf stack install /src/test/stack >/dev/null
check "rollback restores the original release" test "$(readlink "$ONBEHALF_STACK/current")" = "$v1"
check "rollback retains alice's personal default" test "$(answer alice)" = onbehalf-mock-v2
check "rollback restores bob's default" test "$(answer bob)" = onbehalf-mock-ok
check "rollback removes the obsolete baseline agent link" test ! -L /home/alice/.config/opencode/agents/another-shared-probe.md
check "rollback preserves the same-name personal agent" test "$(sha256sum /home/alice/.config/opencode/agents/onbehalf-probe.md)" = "$agent"

# Removing a curated model also removes access on keys that already exist.
jq 'del(.providers.onbehalf.models["mock-model-v2"])' /src/test/stack/opencode/opencode.json >"$v2/opencode/opencode.json"
onbehalf stack install "$v2" >/dev/null
code=$(request alice /v1/chat/completions '{"model":"mock-model-v2","messages":[{"role":"user","content":"hi"}]}')
check "catalog removal revokes existing model access ($code)" test "$code" = 403
onbehalf stack install /src/test/stack >/dev/null
check "rollback restores the selected model's access" test "$(answer alice)" = onbehalf-mock-v2

# Invalid catalogs must not activate or remove all key restrictions.
for filter in '.providers.onbehalf.models = {}' '.model = "onbehalf/private-model"' '.providers.onbehalf.models["*"] = {}' '.providers.onbehalf.models["missing-model"] = {}' \
  'del(.enabled_providers)' '.enabled_providers += ["opencode"]'; do
  jq "$filter" /src/test/stack/opencode/opencode.json >"$v2/opencode/opencode.json"
  check "invalid catalog is rejected: $filter" bash -c '! onbehalf stack install "$1" >/dev/null 2>&1' _ "$v2"
  check "invalid catalog leaves the release unchanged" test "$(readlink "$ONBEHALF_STACK/current")" = "$v1"
done

# OpenCode's built-in providers bypass the gateway; the stack turns them off.
providers_of() {
  as "$1" 'opencode service start >/dev/null 2>&1
    for i in 1 2 3 4 5 6; do out=$(opencode models 2>/dev/null); [ -n "$out" ] && break; sleep 2; done
    printf "%s\n" "$out"' | cut -d/ -f1 | sort -u | tr '\n' ' '
}
for u in "${PEOPLE[@]}"; do
  seen=$(providers_of "$u")
  check "$u sees only the stack's gateway provider ($seen)" test "$seen" = "onbehalf "
done
out=$(onbehalf doctor 2>&1)
check "doctor confirms the stack allows only its gateway providers" grep -q "the shared stack permits only its gateway providers" <<<"$out"
# A release from before this rule: doctor warns and names the fix.
cfg="$ONBEHALF_STACK/current/opencode/opencode.json"
cp -p "$cfg" /tmp/opencode.json.keep
jq 'del(.enabled_providers)' /tmp/opencode.json.keep >"$cfg"
out=$(onbehalf doctor 2>&1)
check "doctor warns about a stack that does not limit providers" grep -q "the shared stack does not limit the providers" <<<"$out"
check "doctor names the providers to allow" grep -q '"enabled_providers": \["onbehalf"\]' <<<"$out"
cp -p /tmp/opencode.json.keep "$cfg" && rm -f /tmp/opencode.json.keep

# Display aliases grant only their API ID; disabled entries grant no access.
jq '.providers.onbehalf.models.friendly = {"modelID":"mock-model"} |
  .providers.onbehalf.models["private-model"] = {"disabled":true} |
  .model = "onbehalf/friendly"' /src/test/stack/opencode/opencode.json >"$v2/opencode/opencode.json"
check "a curated display alias installs" onbehalf stack install "$v2"
check "the display alias calls the configured API model" test "$(answer bob)" = onbehalf-mock-ok
code=$(request bob /v1/chat/completions '{"model":"private-model","messages":[{"role":"user","content":"hi"}]}')
check "a disabled catalog entry grants no access ($code)" test "$code" = 403
onbehalf stack install /src/test/stack >/dev/null

# The default model is part of the team's content, not the contract.
jq 'del(.model)' /src/test/stack/opencode/opencode.json >"$v2/opencode/opencode.json"
check "a stack without a default model installs" onbehalf stack install "$v2"
onbehalf stack install /src/test/stack >/dev/null

printf '{}\n' >"$v2/opencode/opencode.jsonc"
check "a stack cannot overwrite the personal JSONC layer" bash -c '! onbehalf stack install "$1" >/dev/null 2>&1' _ "$v2"
check "a JSONC conflict leaves the release unchanged" test "$(readlink "$ONBEHALF_STACK/current")" = "$v1"

badconf=$(mktemp -d)
cp /etc/onbehalf/onbehalf.conf "$badconf/onbehalf.conf"
printf invalid-test-key >"$badconf/gateway-admin.key"
check "gateway authentication failure stops activation" bash -c 'ONBEHALF_ETC="$1"; export ONBEHALF_ETC; ! onbehalf stack install /src/test/stack >/dev/null 2>&1' _ "$badconf"
check "gateway failure leaves the release unchanged" test "$(readlink "$ONBEHALF_STACK/current")" = "$v1"
rm -rf "$badconf"

as alice 'rm ~/.config/opencode/opencode.jsonc ~/.config/opencode/agents/personal-probe.md ~/.config/opencode/agents/onbehalf-probe.md'
onbehalf user add alice >/dev/null
as alice 'opencode service restart' >/dev/null
rm -rf "$v2"
exit $FAILED
