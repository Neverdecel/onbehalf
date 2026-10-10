#!/usr/bin/env bash
# The Claude Code adapter. The host changes to Claude Code with a neutral
# stack source, and a new user gets the managed settings, the links and the
# personal gateway key. Only a test host with Claude Code runs this check.
set -uo pipefail
. /src/test/lib.sh

if ! command -v claude >/dev/null; then
  echo "  skip  Claude Code is not installed on this test host"
  exit 0
fi

answer() { as "$1" "cd ~ && timeout 180 claude -p 'which model?'" 2>&1 | grep -o 'onbehalf-mock-[a-z0-9]*' | head -1; }
managed=/etc/claude-code/managed-settings.json
conf=/etc/onbehalf/onbehalf.conf
cp -p "$conf" "$conf.orig"

out=$(onbehalf init --harness claude --gateway-url "$ONBEHALF_GATEWAY_URL" </etc/onbehalf/gateway-admin.key 2>&1)
check "init selects Claude Code" grep -qx 'ONBEHALF_HARNESS=claude' "$conf"
check "init checks the messages API of the gateway" grep -q "the gateway serves the API of Claude Code" <<<"$out"

out=$(onbehalf stack install /src/test/stack 2>&1)
check "install refuses a stack source without models.json for Claude Code" grep -q "Claude Code needs models.json" <<<"$out"

src=$(mktemp -d)
mkdir -p "$src/claude/agents"
jq -n '{model: "mock-model", models: {"mock-model": {}, "mock-model-v2": {}}}' >"$src/models.json"
printf '# Team instructions\n\nThe neutral stack gives these instructions.\n' >"$src/AGENTS.md"
cp -R /src/test/stack/opencode/skills "$src/skills"
printf -- '---\nname: onbehalf-probe\ndescription: A probe agent of the tests.\n---\nSay probe.\n' >"$src/claude/agents/onbehalf-probe.md"
echo '{"cleanupPeriodDays": 7}' >"$src/claude/managed-settings.json"

bad=$(mktemp -d)
cp -R "$src/." "$bad"
echo '{"model": "mock-model"}' >"$bad/claude/managed-settings.json"
out=$(onbehalf stack install "$bad" 2>&1)
check "install refuses a model in the managed settings of the team" grep -q "onbehalf writes them from models.json" <<<"$out"

out=$(onbehalf stack install "$src" 2>&1)
check "onbehalf stack install of a neutral stack for Claude Code succeeds" test $? -eq 0
sed 's/^/        /' <<<"$out"
cfg="$ONBEHALF_STACK/current/claude/managed-settings.json"
check "the managed settings of the host are the managed settings of the release" test "$(readlink "$managed")" = "$cfg"
check "the managed settings permit only the model catalog" \
  test "$(jq -c .availableModels "$cfg")" = '["mock-model","mock-model-v2"]'
check "the managed settings use the gateway and the personal gateway key" \
  jq -e --arg url "$ONBEHALF_GATEWAY_URL" '.env.ANTHROPIC_BASE_URL == $url and
    (.apiKeyHelper | contains(".config/onbehalf/gateway.key"))' "$cfg"
check "the managed settings give the default model through the aliases" \
  jq -e '.env.ANTHROPIC_DEFAULT_SONNET_MODEL == "mock-model" and (has("model") | not)' "$cfg"
check "the managed settings keep the settings of the team" test "$(jq -r .cleanupPeriodDays "$cfg")" = 7

out=$(onbehalf user add carol 2>&1)
check "user add carol succeeds" test $? -eq 0
sed 's/^/        /' <<<"$out"
check "carol has the shared harness instructions as CLAUDE.md" \
  test "$(readlink /home/carol/.claude/CLAUDE.md)" = "$ONBEHALF_STACK/current/claude/AGENTS.md"
check "carol has the skill of the root skills/" test -L /home/carol/.claude/skills/onbehalf-probe
check "carol has the agent of claude/" test -L /home/carol/.claude/agents/onbehalf-probe.md
check "carol cannot read the gateway key of alice" denied carol "cat /home/alice/.config/onbehalf/gateway.key"

check "Claude Code of carol answers through the gateway with the default model" test "$(answer carol)" = onbehalf-mock-ok
out=$(onbehalf doctor --user carol 2>&1)
check "doctor: Claude Code of carol uses the shared stack" grep -q "Claude Code uses the shared stack" <<<"$out"
check "doctor: the gateway key of carol permits only the model catalog" \
  grep -q "gateway key permits only the model catalog" <<<"$out"

# A personal default model wins over the default of the team, also after a
# stack update.
as carol "echo '{\"model\": \"mock-model-v2\"}' > ~/.claude/settings.json"
check "the personal model of carol wins over the team default" test "$(answer carol)" = onbehalf-mock-v2
echo '# A change of the team' >>"$src/AGENTS.md"
onbehalf stack install "$src" >/dev/null 2>&1
check "the personal model stays after a stack update" test "$(answer carol)" = onbehalf-mock-v2
check "the stack update keeps the managed settings link" test "$(readlink "$managed")" = "$cfg"

as carol "echo '{\"x\": 1}' > ~/.claude/.credentials.json"
out=$(onbehalf doctor --user carol 2>&1)
check "doctor finds personal credentials that go around the gateway" \
  grep -q "personal model credentials in ~/.claude/.credentials.json" <<<"$out"

out=$(as carol "onbehalf restart" 2>&1)
check "restart tells that Claude Code has no service" grep -q "Claude Code has no service to restart" <<<"$out"

# Back to OpenCode for the other checks.
onbehalf user remove carol >/dev/null 2>&1
rm -f "$managed"
mv "$conf.orig" "$conf"
onbehalf stack install /src/test/stack >/dev/null 2>&1
check "the host uses OpenCode again" grep -qx 'ONBEHALF_HARNESS=opencode' "$conf"

rm -rf "$src" "$bad"
exit $FAILED
