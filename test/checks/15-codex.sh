#!/usr/bin/env bash
# The Codex adapter. The host changes to Codex with a neutral stack source,
# and a new user gets the system configuration, the links and the personal
# gateway key. Only a test host with Codex runs this check.
set -uo pipefail
. /src/test/lib.sh

if ! command -v codex >/dev/null; then
  echo "  skip  Codex is not installed on this test host"
  exit 0
fi

# The fake model answers the responses API with the name of the model.
answer() {
  as "$1" "cd ~ && timeout 180 codex exec --skip-git-repo-check ${2:-} 'which model?'" 2>&1 \
    | grep -o 'onbehalf-responses-[a-z0-9-]*\|not available for this API key' | head -1
}
config=/etc/codex/config.toml
conf=/etc/onbehalf/onbehalf.conf
cp -p "$conf" "$conf.orig"

out=$(onbehalf init --harness codex --gateway-url "$ONBEHALF_GATEWAY_URL" </etc/onbehalf/gateway-admin.key 2>&1)
check "init selects Codex" grep -qx 'ONBEHALF_HARNESS=codex' "$conf"
check "init checks the responses API of the gateway" grep -q "the gateway serves the API of Codex" <<<"$out"

out=$(onbehalf stack install /src/test/stack 2>&1)
check "install refuses a stack source without models.json for Codex" grep -q "Codex needs models.json" <<<"$out"

src=$(mktemp -d)
mkdir -p "$src/codex"
jq -n '{model: "agent-model", models: {"agent-model": {}, "agent-model-v2": {}}}' >"$src/models.json"
printf '# Team instructions\n\nThe team word is onbehalf-team-word.\n' >"$src/AGENTS.md"
cp -R /src/test/stack/opencode/skills "$src/skills"
printf 'hide_agent_reasoning = true\n\n[history]\npersistence = "none"\n' >"$src/codex/config.toml"

bad=$(mktemp -d)
cp -R "$src/." "$bad"
echo 'model = "agent-model"' >"$bad/codex/config.toml"
out=$(onbehalf stack install "$bad" 2>&1)
check "install refuses a model in the Codex configuration of the team" grep -q "onbehalf writes them from models.json" <<<"$out"

out=$(onbehalf stack install "$src" 2>&1)
check "onbehalf stack install of a neutral stack for Codex succeeds" test $? -eq 0
sed 's/^/        /' <<<"$out"
cfg="$ONBEHALF_STACK/current/codex/config.toml"
check "the system configuration of the host is the configuration of the release" test "$(readlink "$config")" = "$cfg"
check "the system configuration has the default model and the gateway provider" \
  bash -c 'grep -qx "model = \"agent-model\"" "$1" && grep -qx "model_provider = \"onbehalf\"" "$1" &&
    grep -qx "base_url = \"$2/v1\"" "$1"' _ "$cfg" "$ONBEHALF_GATEWAY_URL"
check "the system configuration uses the personal gateway key" grep -q '\.config/onbehalf/gateway\.key' "$cfg"
check "the system configuration keeps the settings of the team" \
  bash -c 'grep -qx "hide_agent_reasoning = true" "$1" && grep -qx "persistence = \"none\"" "$1"' _ "$cfg"

out=$(onbehalf user add carol 2>&1)
check "user add carol succeeds" test $? -eq 0
sed 's/^/        /' <<<"$out"
check "carol has the shared harness instructions" \
  test "$(readlink /home/carol/.codex/AGENTS.md)" = "$ONBEHALF_STACK/current/codex/AGENTS.md"
check "carol has the skill of the root skills/" test -L /home/carol/.codex/skills/onbehalf-probe
check "carol cannot read the gateway key of alice" denied carol "cat /home/alice/.config/onbehalf/gateway.key"
check "the gateway key of carol permits only the responses API" \
  test "$(admin_get "/key/info?key=$(sha256sum /home/carol/.config/onbehalf/gateway.key | cut -d' ' -f1)" \
    | jq -c '.info.allowed_routes | map(select(test("completions|messages")))')" = '[]'

check "Codex of carol answers through the gateway with the default model" \
  test "$(answer carol)" = onbehalf-responses-agent-model
# The gateway writes its spend logs in batches.
sent=
for _ in $(seq 1 15); do
  sent=$(admin_get "/spend/logs?user_id=carol" | jq -r 'tostring')
  [[ $sent != *onbehalf-team-word* ]] || break
  sleep 2
done
check "the request of carol has the shared harness instructions" grep -q onbehalf-team-word <<<"$sent"
check "the request of carol has the shared skill" grep -q onbehalf-probe <<<"$sent"
check "the gateway refuses a model that is not in the model catalog" \
  test "$(answer carol '-m private-model')" = "not available for this API key"
out=$(onbehalf doctor --user carol --model-check 2>&1)
check "doctor: Codex of carol uses the shared stack" grep -q "Codex uses the shared stack" <<<"$out"
check "doctor: the gateway key of carol permits only the model catalog" \
  grep -q "gateway key permits only the model catalog" <<<"$out"
check "doctor: the model access check uses the responses API" grep -q "agent-model answered" <<<"$out"

# A personal default model wins over the default of the team, also after a
# stack update.
as carol "echo 'model = \"agent-model-v2\"' > ~/.codex/config.toml"
check "the personal model of carol wins over the team default" test "$(answer carol)" = onbehalf-responses-agent-model-v2
echo '# A change of the team' >>"$src/AGENTS.md"
onbehalf stack install "$src" >/dev/null 2>&1
check "the personal model stays after a stack update" test "$(answer carol)" = onbehalf-responses-agent-model-v2
check "the stack update keeps the system configuration link" test "$(readlink "$config")" = "$cfg"

as carol "echo '{\"x\": 1}' > ~/.codex/auth.json"
out=$(onbehalf doctor --user carol 2>&1)
check "doctor finds personal credentials that go around the gateway" \
  grep -q "personal model credentials in ~/.codex/auth.json" <<<"$out"

out=$(as carol "onbehalf restart" 2>&1)
check "restart tells that Codex has no service" grep -q "Codex has no service to restart" <<<"$out"

# Back to OpenCode for the other checks.
onbehalf user remove carol >/dev/null 2>&1
rm -f "$config"
mv "$conf.orig" "$conf"
onbehalf stack install /src/test/stack >/dev/null 2>&1
check "the host uses OpenCode again" grep -qx 'ONBEHALF_HARNESS=opencode' "$conf"

rm -rf "$src" "$bad"
exit $FAILED
