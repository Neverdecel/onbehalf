#!/usr/bin/env bash
# Status plugin: the plugin of the example stack records a short status for
# each session in the home directory of the user. A board reads it through
# the OpenCode API of that user, with the route of `onbehalf route`.
set -uo pipefail
. /src/test/lib.sh

STATE=.local/state/onbehalf/sessions.json

# 10-offboarding removed bob. carol is the user of this check.
useradd -m -s /bin/bash carol
onbehalf user add carol >/dev/null 2>&1

# The test stack with the plugin. The fake model of agent-model makes a
# session run an exact command, and the stack asks before each command.
src=$(mktemp -d)
cp -R /src/test/stack/. "$src"
install -D -m 0644 /src/examples/stack/opencode/plugins/onbehalf-status.js "$src/opencode/plugins/onbehalf-status.js"
jq '.model = "onbehalf/agent-model" | .permission = {shell: "ask"}' /src/test/stack/opencode/opencode.json >"$src/opencode/opencode.json"
out=$(onbehalf stack install "$src" 2>&1)
check "the stack with the status plugin installs" test $? -eq 0 || sed 's/^/        /' <<<"$out"
as carol "opencode service start" >/dev/null 2>&1

route=$(onbehalf route carol 2>/dev/null)
url=$(jq -r .url <<<"$route")
auth="opencode:$(jq -r .password <<<"$route")"
api() { curl -s --max-time 10 -u "$auth" -H 'content-type: application/json' "$@"; }
# status ID: the status record of session ID, read through the OpenCode API.
status() { api "$url/api/fs/read/$STATE?path=~" | jq -c --arg id "$1" '.[$id] // empty'; }
# wait_for ID STATUS: wait until session ID has STATUS.
wait_for() {
  for _ in $(seq 40); do
    [ "$(status "$1" | jq -r .status)" = "$2" ] && return 0
    sleep 0.5
  done
  return 1
}

# A session that ends: Done, with the last line of the answer.
as carol "cd ~ && timeout 180 opencode run 'say hi'" >/dev/null 2>&1
id=$(api "$url/api/session" | jq -r '.data[0].id // empty')
check "the plugin records a session that ends as done" wait_for "$id" "done"
check "the record has the last line of the answer" bash -c '[ "$(jq -r .line <<<"$1")" = onbehalf-agent-idle ]' _ "$(status "$id")"

# A session that waits for a permission: Blocked, with the question.
id=$(api -d '{}' "$url/api/session" | jq -r '.data.id // empty')
api -d '{"text":"RUN: touch /tmp/status-test"}' "$url/api/session/$id/prompt" >/dev/null
check "the plugin records a session that waits for a permission as blocked" wait_for "$id" blocked
check "the record has the open permission request" bash -c 'jq -r .question <<<"$1" | grep -q "touch /tmp/status-test"' _ "$(status "$id")"

# The user refuses the permission: the session stops.
rid=$(api "$url/api/session/$id/permission" | jq -r '.data[0].id // empty')
api -d '{"decision":"reject"}' "$url/api/session/$id/permission/$rid/reply" >/dev/null
check "a refused permission stops the session" wait_for "$id" stopped
check "the record of a stopped session has no open question" bash -c '[ -z "$(jq -r .question <<<"$1")" ]' _ "$(status "$id")"

# Only carol can read her status file.
check "the status file has mode 600" test "$(stat -c %a "/home/carol/$STATE")" = 600
check "a different user cannot read the status file" denied alice "cat /home/carol/$STATE"

onbehalf stack install /src/test/stack >/dev/null 2>&1
check "the test stack without the plugin is back (test cleanup)" test ! -e /home/carol/.config/opencode/plugins/onbehalf-status.js
onbehalf user remove carol >/dev/null 2>&1
check "carol is removed (test cleanup)" bash -c '! id carol' 2>/dev/null
rm -rf "$src"

exit $FAILED
