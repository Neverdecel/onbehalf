#!/usr/bin/env bash
# Shared agent: the whoami agent of the example stack reaches every user.
# It runs its identity command without a question, and it asks before any
# other command. A fake model makes the agent run an exact shell command (see
# test/fake-model/server.js). `opencode run` cannot ask, so it rejects.
set -uo pipefail
. /src/test/lib.sh

src=$(mktemp -d)
cp -R /src/test/stack/. "$src"
cp /src/examples/stack/opencode/agents/whoami.md "$src/opencode/agents/"
out=$(onbehalf stack install "$src" 2>&1)
check "the stack with the example whoami agent installs" test $? -eq 0
sed 's/^/        /' <<<"$out"

whoami_run() {
  as "$1" "cd ~ && timeout 180 opencode run --agent whoami -m onbehalf/agent-model 'RUN: $2'" 2>&1
}

# expect MESSAGE PATTERN OUTPUT: pass if OUTPUT has a line matching PATTERN.
expect() {
  if grep -qE "$2" <<<"$3"; then
    pass "$1"
  else
    fail "$1"
    tail -10 <<<"$3" | sed 's/^/        /'
  fi
}

for u in "${PEOPLE[@]}"; do
  out=$(whoami_run "$u" "id -un")
  expect "$u's whoami agent runs id -un without a question" "^$u\$" "$out"

  marker=/home/$u/whoami-$(date +%s%N)
  out=$(whoami_run "$u" "touch $marker")
  expect "$u's whoami agent asks before another command" 'permission requested' "$out"
  check "$u's whoami agent does not run a command without approval" test ! -e "$marker"
done

onbehalf stack install /src/test/stack >/dev/null
rm -rf "$src"
exit $FAILED
