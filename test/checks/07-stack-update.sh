#!/usr/bin/env bash
# Same setup (MVP step 7): every user uses the agents, skills and model of
# the shared stack. One stack change reaches every user, also when their
# agent service is already running, and an older release can be restored.
set -uo pipefail
. /src/test/lib.sh

answer() { as "$1" "cd ~ && timeout 180 opencode run 'which model?'" 2>&1 | grep -o 'onbehalf-mock-[a-z0-9]*' | head -1; }
agents() { as "$1" "opencode debug agents" | jq -r '.[] | .name // .id' | sort | tr '\n' ' '; }
# OpenCode loads its skill list after the first request, so call this after answer().
skills() { as "$1" "opencode api GET /api/skill" | grep -o '"id":"[^"]*","name"' | cut -d'"' -f4 | sort | tr '\n' ' '; }
release() { readlink "$ONBEHALF_STACK/current"; }

# Expect every user to answer with model $1 and have agent $2.
expect_stack() {
  local model=$1 agent=$2 u a
  for u in "${PEOPLE[@]}"; do
    a=$(answer "$u")
    check "$u uses the stack model ($a)" test "$a" = "$model"
    check "$u has the stack agent $agent" grep -qw "$agent" <<<"$(agents "$u")"
  done
}

v1=$(release)
expect_stack onbehalf-mock-ok onbehalf-probe
for u in "${PEOPLE[@]}"; do
  check "$u has the stack skill onbehalf-probe" grep -qw onbehalf-probe <<<"$(skills "$u")"
done
check "alice and bob have the same agents" test "$(agents alice)" = "$(agents bob)"
check "alice and bob have the same skills" test "$(skills alice)" = "$(skills bob)"

# Release 2: another model and one more agent. The services are running now.
v2src=$(mktemp -d)
cp -R /src/test/stack/. "$v2src"
jq '.model = "onbehalf/mock-model-v2"' /src/test/stack/opencode/opencode.json >"$v2src/opencode/opencode.json"
sed 's/^description: .*/description: Second probe agent, added in release 2 of the test stack./' \
  /src/test/stack/opencode/agents/onbehalf-probe.md >"$v2src/opencode/agents/onbehalf-probe-v2.md"

# alice adds her own tool directory to PATH as the user guide says. The
# restart by the stack install must keep it, also on hosts whose login
# profile does not add ~/.local/bin.
# Read the environment as the user: the host can deny it to root.
service_path() { as "$1" "tr '\0' '\n' </proc/$(pgrep -u "$1" -n -f 'serve --service')/environ" | sed -n 's/^PATH=//p'; }
profile=$(as alice 'f=~/.profile; [ -f ~/.bash_profile ] && f=~/.bash_profile; echo "$f"')
cp -p "$profile" "$profile.orig"
as alice "mkdir -p ~/.local/bin && echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >>$profile"

check "services are running before the change (test setup)" pgrep -f 'serve --service'
out=$(onbehalf stack install "$v2src" 2>&1)
check "onbehalf stack install of release 2 succeeds" test $? -eq 0
sed 's/^/        /' <<<"$out"
expect_stack onbehalf-mock-v2 onbehalf-probe-v2
check "alice's restarted service has her ~/.local/bin in PATH" grep -q '/home/alice/.local/bin' <<<"$(service_path alice)"
mv "$profile.orig" "$profile"

# Roll back: installing the old stack again restores the same release.
out=$(onbehalf stack install /src/test/stack 2>&1)
check "rollback to release 1 succeeds" test $? -eq 0
check "rollback restores the same release ($(release))" test "$(release)" = "$v1"
expect_stack onbehalf-mock-ok onbehalf-probe
for u in "${PEOPLE[@]}"; do
  check "$u no longer has the release 2 agent" bash -c "! grep -qw onbehalf-probe-v2 <<<'$(agents "$u")'"
done

rm -rf "$v2src"
exit $FAILED
