#!/usr/bin/env bash
# A stack source that does not depend on the AI harness: models.json is the
# model catalog, AGENTS.md and skills/ are at the root. The OpenCode adapter
# writes the gateway providers. Each user gets the same result as from a
# stack source with opencode/opencode.json.
set -uo pipefail
. /src/test/lib.sh

answer() { as "$1" "cd ~ && timeout 180 opencode run 'which model?'" 2>&1 | grep -o 'onbehalf-mock-[a-z0-9]*' | head -1; }
agents() { as "$1" "opencode debug agents" | jq -r '.[] | .name // .id' | sort | tr '\n' ' '; }
# OpenCode loads its skill list after the first request, so call this after answer().
skills() { as "$1" "opencode api GET /api/skill" | grep -o '"id":"[^"]*","name"' | cut -d'"' -f4 | sort | tr '\n' ' '; }
release() { readlink "$ONBEHALF_STACK/current"; }

legacy=$(release)
src=$(mktemp -d)
mkdir -p "$src/opencode/agents"
jq -n '{model: "mock-model-v2", models: {"mock-model": {}, "mock-model-v2": {}, "agent-model": {}, "blocked-model": {}}}' >"$src/models.json"
echo '{"update": "disable"}' >"$src/opencode/opencode.json"
printf '# Team instructions\n\nThe neutral stack gives these instructions.\n' >"$src/AGENTS.md"
cp -R /src/test/stack/opencode/skills "$src/skills"
cp /src/test/stack/opencode/agents/onbehalf-probe.md "$src/opencode/agents/"

out=$(onbehalf stack install "$src" 2>&1)
check "onbehalf stack install of a neutral stack succeeds" test $? -eq 0
sed 's/^/        /' <<<"$out"
cfg="$ONBEHALF_STACK/current/opencode/opencode.json"
check "the release has the gateway provider with the model catalog" \
  test "$(jq -c '.providers.onbehalf.models | keys' "$cfg")" = '["agent-model","blocked-model","mock-model","mock-model-v2"]'
check "the release permits only the gateway provider" test "$(jq -c .enabled_providers "$cfg")" = '["onbehalf"]'
check "the release keeps the settings of the team" test "$(jq -r .update "$cfg")" = disable
check "the release has the default model of models.json" test "$(jq -r .model "$cfg")" = onbehalf/mock-model-v2
check "the release gives the root AGENTS.md to OpenCode" cmp -s "$src/AGENTS.md" "$ONBEHALF_STACK/current/opencode/AGENTS.md"

# The earlier checks can remove users. Check the users that are still here.
for u in "${PEOPLE[@]}"; do
  id "$u" >/dev/null 2>&1 || continue
  a=$(answer "$u")
  check "$u uses the default model of models.json ($a)" test "$a" = onbehalf-mock-v2
  check "$u has the agent of opencode/" grep -qw onbehalf-probe <<<"$(agents "$u")"
  check "$u has the skill of the root skills/" grep -qw onbehalf-probe <<<"$(skills "$u")"
  check "$u has the root harness instructions" \
    test "$(readlink "/home/$u/.config/opencode/AGENTS.md")" = "$ONBEHALF_STACK/current/opencode/AGENTS.md"
done
out=$(onbehalf doctor --user alice 2>&1)
check "the gateway key of alice permits the model catalog of models.json" \
  grep -q "gateway key permits only the model catalog" <<<"$out"

# The stack source has one place for each item.
neutral=$(release)
bad=$(mktemp -d)
cp -R "$src/." "$bad"
echo '# second' >"$bad/opencode/AGENTS.md"
out=$(onbehalf stack install "$bad" 2>&1)
check "install refuses AGENTS.md at the root and in opencode/" grep -q "AGENTS.md is at the root and in opencode/" <<<"$out"
rm "$bad/opencode/AGENTS.md"
jq '.providers = {}' "$src/opencode/opencode.json" >"$bad/opencode/opencode.json"
out=$(onbehalf stack install "$bad" 2>&1)
check "install refuses providers in opencode.json next to models.json" grep -q "onbehalf writes them from models.json" <<<"$out"
check "the refused installs keep the current release" test "$(release)" = "$neutral"

# Back to the stack source of the other checks.
out=$(onbehalf stack install /src/test/stack 2>&1)
check "install of the opencode.json stack source again succeeds" test $? -eq 0
check "it restores the same release ($(release))" test "$(release)" = "$legacy"
check "alice uses the default model of opencode.json again" test "$(answer alice)" = onbehalf-mock-ok

rm -rf "$src" "$bad"
exit $FAILED
