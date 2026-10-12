#!/usr/bin/env bash
# onbehalf harness NAME: the host changes its AI harness, and each user
# gets the new AI harness with the same gateway key. Only a test host with
# Claude Code and Codex runs this check.
set -uo pipefail
. /src/test/lib.sh

if ! command -v claude >/dev/null || ! command -v codex >/dev/null; then
  echo "  skip  Claude Code and Codex are not installed on this test host"
  exit 0
fi

conf=/etc/onbehalf/onbehalf.conf
routes() {
  admin_get "/key/info?key=$(sha256sum "/home/$1/.config/onbehalf/gateway.key" | cut -d' ' -f1)" \
    | jq -r '.info.allowed_routes | map(select(test("^/v1/(chat|messages$|responses)"))) | join(" ")'
}

out=$(onbehalf harness nothere 2>&1)
check "harness refuses an AI harness that onbehalf does not support" grep -q "NAME is one of: opencode claude codex" <<<"$out"
out=$(onbehalf harness opencode 2>&1)
check "harness tells that the host has this AI harness" grep -q "OpenCode is the AI harness of this host" <<<"$out"

# A stack source without models.json serves only OpenCode.
before=$(sha256sum "$conf")
out=$(onbehalf harness claude 2>&1)
check "harness refuses a shared stack without the new AI harness" grep -q "the shared stack has no configuration for Claude Code" <<<"$out"
check "the refused change keeps the configuration" test "$(sha256sum "$conf")" = "$before"

src=$(mktemp -d)
jq -n '{model: "mock-model", models: {"mock-model": {}, "agent-model": {}}}' >"$src/models.json"
printf '# Team instructions\n' >"$src/AGENTS.md"
cp -R /src/test/stack/opencode/skills "$src/skills"
onbehalf stack install "$src" >/dev/null 2>&1
onbehalf user add carol >/dev/null 2>&1
key=$(sha256sum /home/carol/.config/onbehalf/gateway.key)
as carol "echo '{}' > ~/.config/opencode/opencode.jsonc"
check "carol starts with the links of OpenCode" test -L /home/carol/.config/opencode/opencode.json

out=$(onbehalf harness claude 2>&1)
check "onbehalf harness claude succeeds" test $? -eq 0
sed 's/^/        /' <<<"$out"
check "the configuration has Claude Code" grep -qx 'ONBEHALF_HARNESS=claude' "$conf"
check "the links of OpenCode are gone" test ! -e /home/carol/.config/opencode/opencode.json -a ! -L /home/carol/.config/opencode/AGENTS.md
check "the personal OpenCode settings of carol stay" test -f /home/carol/.config/opencode/opencode.jsonc
check "the OpenCode service of carol does not run" bash -c '! pgrep -u carol -f "serve --service" >/dev/null'
check "carol has the links of Claude Code" test -L /home/carol/.claude/CLAUDE.md -a -L /home/carol/.claude/skills/onbehalf-probe
check "the host has the managed settings of Claude Code" test -L /etc/claude-code/managed-settings.json
check "carol keeps the gateway key" test "$(sha256sum /home/carol/.config/onbehalf/gateway.key)" = "$key"
check "the gateway key of carol permits only the messages API" test "$(routes carol)" = "/v1/messages"
check "Claude Code of carol answers through the gateway" \
  test "$(as carol "cd ~ && timeout 180 claude -p 'which model?'" 2>&1 | grep -o 'onbehalf-mock-[a-z0-9]*' | head -1)" = onbehalf-mock-ok
out=$(onbehalf doctor 2>&1)
check "doctor has no errors after the change to Claude Code" grep -q "host configuration: no errors" <<<"$out"

out=$(onbehalf harness codex 2>&1)
check "onbehalf harness codex succeeds" test $? -eq 0
check "the configuration has Codex" grep -qx 'ONBEHALF_HARNESS=codex' "$conf"
check "the managed settings of Claude Code are gone" test ! -e /etc/claude-code/managed-settings.json -a ! -L /etc/claude-code/managed-settings.json
check "the links of Claude Code are gone" test ! -L /home/carol/.claude/CLAUDE.md -a ! -L /home/carol/.claude/skills/onbehalf-probe
check "carol has the links of Codex" test -L /home/carol/.codex/AGENTS.md -a -L /home/carol/.codex/skills/onbehalf-probe
check "the gateway key of carol permits only the responses API" test "$(routes carol)" = "/v1/responses"
check "Codex of carol answers through the gateway" \
  test "$(as carol "cd ~ && timeout 180 codex exec --skip-git-repo-check -m agent-model 'which model?'" 2>&1 \
    | grep -o 'onbehalf-responses-[a-z0-9-]*' | head -1)" = onbehalf-responses-agent-model
out=$(onbehalf doctor 2>&1)
check "doctor has no errors after the change to Codex" grep -q "host configuration: no errors" <<<"$out"

out=$(onbehalf harness opencode 2>&1)
check "onbehalf harness opencode succeeds" test $? -eq 0
check "the system configuration of Codex is gone" test ! -e /etc/codex/config.toml -a ! -L /etc/codex/config.toml
check "carol has the links of OpenCode again" test -L /home/carol/.config/opencode/opencode.json
check "the gateway key of carol permits the chat completions API again" grep -q /v1/chat/completions <<<"$(routes carol)"
check "OpenCode of carol answers through the gateway" \
  test "$(as carol "cd ~ && timeout 180 opencode run 'which model?'" 2>&1 | grep -o 'onbehalf-mock-[a-z0-9]*' | head -1)" = onbehalf-mock-ok
check "alice has the links of OpenCode again" test -L /home/alice/.config/opencode/opencode.json

# Back to the stack of the other checks.
onbehalf user remove carol >/dev/null 2>&1
onbehalf stack install /src/test/stack >/dev/null 2>&1
out=$(onbehalf doctor 2>&1)
check "doctor has no errors with the first stack" grep -q "host configuration: no errors" <<<"$out"

rm -rf "$src"
exit $FAILED
