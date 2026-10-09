# shellcheck shell=bash disable=SC2034,SC2154 # TOOL_* is read by tools.sh; colours come from ui.sh
# Work tools of the shared stack: the operator adds a tool for the team with
# one file, tools/ID.json, in the stack source. No change to onbehalf.
#
#   label, help   one line each, for the menu and the summary
#   command       the program; not installed means missing
#   check         arguments of a command without prompts: exit 0 means ok
#   login         arguments of the native login of the tool
#   whoami        optional: arguments of a command that prints the account
#
# Commands are lists of arguments, never shell code. stack install checks
# each file (stack_tool_valid); a stack tool cannot replace a built-in tool.

TOOLS_DISCOVER+=(tool_stack_discover)

tool_stack_dir() { echo "${ONBEHALF_STACK:-/opt/onbehalf/stack}/current/tools"; }

tool_stack_discover() {
  local f id
  for f in "$(tool_stack_dir)"/*.json; do
    [ -f "$f" ] || continue
    id=${f##*/} id=${id%.json}
    stack_tool_id_ok "$id" && stack_tool_valid "$f" || continue
    tool_register "$id" "$(jq -r .label "$f")" "$(jq -r .help "$f")" tool_stack "$id"
  done
}

# tool_stack_args ARRAY ID FIELD: the arguments of a command of the tool.
tool_stack_args() {
  mapfile -t "$1" < <(jq -r --arg k "$3" '.[$k] // [] | .[]' "$(tool_stack_dir)/$2.json")
}

tool_stack_state() {
  local f cmd args=() user
  f="$(tool_stack_dir)/$1.json"
  cmd=$(jq -r .command "$f")
  if ! command -v "$cmd" >/dev/null; then
    TOOL_STATE=missing TOOL_DETAIL="not installed"
    return 0
  fi
  tool_stack_args args "$1" check
  if ! (cd ~ && timeout 30 "${args[@]}") </dev/null >/dev/null 2>&1; then
    TOOL_STATE=todo TOOL_DETAIL="not logged in"
    return 0
  fi
  TOOL_STATE=ok TOOL_DETAIL="logged in"
  tool_stack_args args "$1" whoami
  [ ${#args[@]} -gt 0 ] || return 0
  # One line, without control characters: it goes to the terminal.
  user=$( (cd ~ && timeout 30 "${args[@]}") </dev/null 2>/dev/null | head -1 | tr -d '[:cntrl:]') || user=''
  [ -z "$user" ] || TOOL_DETAIL="logged in as $user" TOOL_BRIEF=$user
}

tool_stack_setup() {
  local login=()
  tool_stack_args login "$1" login
  say "$(jq -r .help "$(tool_stack_dir)/$1.json")"
  note "Now the usual login: ${login[*]}"
  printf '\n'
  tool_native "${login[@]}"
}
