# shellcheck shell=bash disable=SC2034,SC2154 # MENU_* is read by menu.sh; colours come from ui.sh
# Work tools: the settings and logins the agent uses to act as the user.
# `onbehalf tools` sets them up with the native login of each tool. It runs as
# the user, without root, and never sees or stores a credential.
#
# Each tool is a module in tools/ that calls tool_register and defines two
# functions (HANDLER defaults to tool_ID):
#
#   HANDLER_state [ARG]   no prompts. Sets TOOL_STATE to ok, todo (not set
#                         up), warn (set up, but wrong) or missing (not
#                         installed), TOOL_DETAIL to one line for status and
#                         the summary, and optionally TOOL_BRIEF for the menu.
#   HANDLER_setup [ARG]   the guided setup. Runs native logins with
#                         tool_native. Returns 0 when done (the wizard checks
#                         the state again), 3 when the user kept the current
#                         setup, 130 when cancelled, anything else on failure.
#
# A module can also add a function to TOOLS_DISCOVER that registers more tools
# when the wizard starts: the MCP servers of the shared stack come this way.
#
# The menu and the summary show two groups: the work tools, then the MCP
# connections (the tools with an ID that starts with mcp:).

declare -ga TOOL_IDS=() TOOLS_DISCOVER=() MENU_HEAD=()
declare -gA TOOL_LABEL=() TOOL_HELP=() TOOL_HANDLER=() TOOL_ARG=() TOOL_SEEN=()
TOOLS_LOADED=no

# tool_register ID LABEL HELP [HANDLER [ARG]]
tool_register() {
  [ -n "${TOOL_LABEL[$1]:-}" ] || TOOL_IDS+=("$1")
  TOOL_LABEL[$1]=$2
  TOOL_HELP[$1]=$3
  TOOL_HANDLER[$1]=${4:-tool_$1}
  TOOL_ARG[$1]=${5:-}
}

tools_load() {
  [ "$TOOLS_LOADED" = no ] || return 0
  TOOLS_LOADED=yes
  local f
  for f in "${TOOLS_DISCOVER[@]}"; do "$f"; done
  # The work tools first, then the MCP connections.
  local id tools=() mcp=()
  for id in "${TOOL_IDS[@]}"; do
    [ "$(tool_group "$id")" = mcp ] && mcp+=("$id") || tools+=("$id")
  done
  TOOL_IDS=("${tools[@]}" "${mcp[@]}")
}

# tool_group ID: tool or mcp.
tool_group() { [[ $1 == mcp:* ]] && echo mcp || echo tool; }

# tool_title ID: the label for a line outside the groups, e.g. "tracker (MCP)".
tool_title() {
  [ "$(tool_group "$1")" = mcp ] && echo "${TOOL_LABEL[$1]} (MCP)" || echo "${TOOL_LABEL[$1]}"
}

# tools_headings ARRAY: the group heading before each tool, by index into
# TOOL_IDS, else empty. Only when there are tools in both groups.
tools_headings() {
  local -n _head=$1
  local i last='' g groups=()
  _head=()
  for ((i = 0; i < ${#TOOL_IDS[@]}; i++)); do
    g=$(tool_group "${TOOL_IDS[i]}")
    _head[i]=''
    [ "$g" = "$last" ] && continue
    last=$g
    groups+=("$g")
    [ "$g" = mcp ] && _head[i]="MCP connections" || _head[i]="Work tools"
  done
  [ ${#groups[@]} -gt 1 ] || _head=()
}

# tool_state ID: set TOOL_STATE, TOOL_DETAIL and TOOL_BRIEF.
tool_state() {
  TOOL_STATE=todo TOOL_DETAIL='' TOOL_BRIEF=''
  "${TOOL_HANDLER[$1]}_state" ${TOOL_ARG[$1]:+"${TOOL_ARG[$1]}"}
  [ -n "$TOOL_BRIEF" ] || TOOL_BRIEF=$TOOL_DETAIL
  TOOL_SEEN[$1]=$TOOL_STATE
}

# The last known state of each tool, for the login message: reading the
# states takes seconds (gh and OpenCode ask their servers), a login must not.
tools_state_file() { echo "$HOME/.config/onbehalf/tools-state"; }

# tools_save: keep the states read so far, one "ID<tab>STATE" line each.
tools_save() {
  local id f
  [ ${#TOOL_SEEN[@]} -gt 0 ] || return 0
  f=$(tools_state_file)
  (
    umask 077
    mkdir -p "${f%/*}"
    for id in "${!TOOL_SEEN[@]}"; do printf '%s\t%s\n' "$id" "${TOOL_SEEN[$id]}"; done >"$f.new"
    mv -f "$f.new" "$f"
  ) 2>/dev/null || :
}

# tools_unfinished: the IDs of the tools to set up or fix, as last saved.
tools_unfinished() {
  local f
  f=$(tools_state_file)
  [ -r "$f" ] || return 0
  awk -F '\t' '$2 == "todo" || $2 == "warn" { printf "%s%s", s, $1; s = " " }' "$f"
}

# tools_refresh_later: read the states again in the background, at most once
# a day and after each stack install (it can add tools), for the next login.
# Detached, so it never holds up this login.
tools_refresh_later() {
  local stack=${ONBEHALF_STACK:-/opt/onbehalf/stack}/current newer=()
  [ ! -L "$stack" ] || newer=(-newer "$stack")
  [ -z "$(find "$(tools_state_file)" -mmin -1440 "${newer[@]}" 2>/dev/null)" ] || return 0
  command -v setsid >/dev/null || return 0
  setsid -f nice timeout 120 onbehalf tools --list >/dev/null 2>&1 </dev/null || :
}

# tool_native COMMAND...: run a native login as a child process. Ctrl-C stops
# only this command, not the wizard. Returns 130 when cancelled.
tool_native() {
  local rc=0
  TOOL_CANCELLED=no
  trap 'TOOL_CANCELLED=yes' INT
  "$@" || rc=$?
  trap tools_interrupted INT
  [ "$TOOL_CANCELLED" = no ] || return 130
  return "$rc"
}

tools_interrupted() {
  printf '\e[?25h\n\n  Stopped. Run it again at any time: onbehalf tools\n'
  exit 130
}

# True if prompts can be shown: stdin and stdout are a terminal, and it is
# the controlling terminal (not so under su -c or runuser -c).
tools_terminal() { [ -t 0 ] && [ -t 1 ] && { : </dev/tty; } 2>/dev/null; }

# The Entra account of this user, if linked.
tools_upn() { entra_upn_of "$(id -un)"; }

# The full name of this account (GECOS), for the Git name.
tools_full_name() { getent passwd "$(id -un)" | cut -d: -f5 | cut -d, -f1; }

# What a user does about a tool that is not installed.
tools_missing_hint() {
  if [ -n "$(owner_of "$(id -un)")" ]; then
    echo "not installed · install it on this host (you are its operator)"
  else
    echo "not installed · ask your operator"
  fi
}

# Why this account must not run the wizard; prints nothing if it may.
tools_refusal() {
  local u home
  u=$(id -un)
  home=$(home_of "$u")
  if [ "$(id -u)" = 0 ]; then
    echo "run this as yourself, not as root"
  elif is_operator "$u"; then
    echo "operators run no runtime in this account. Open your runtime account: sudo onbehalf operator shell"
  elif [ -z "$home" ] || [ "$HOME" != "$home" ]; then
    # su without -l or sudo -E: logins would land in another account's files.
    echo "HOME is $HOME, but the home directory of $u is ${home:-unknown}. Log in as $u (su -l, or a new SSH session)"
  else
    return 1
  fi
}

# onbehalf tools [ID...]
cmd_tools() {
  local why id want=() a mk
  why=$(tools_refusal) && die "$why"
  if [ "${1:-}" = --list ]; then
    tools_list
    return 0
  fi
  tools_terminal || die "onbehalf tools must have a terminal"
  [ ! -r "$ONBEHALF_ETC/onbehalf.conf" ] || load_conf
  tools_load
  for a in "$@"; do
    case $a in -h | --help) die "usage: onbehalf tools [${TOOL_IDS[*]}]" ;; esac
    # An MCP server may be named without its mcp: prefix.
    id=''
    for mk in "$a" "mcp:$a"; do
      if [ -n "${TOOL_LABEL[$mk]:-}" ]; then
        id=$mk
        break
      fi
    done
    [ -n "$id" ] || die "unknown work tool: $a (choose from: ${TOOL_IDS[*]})"
    want+=("$id")
  done
  trap tools_interrupted INT
  section "Work tools" "$(id -un)"
  if [ ${#want[@]} = 0 ]; then
    say "The runtime works as you: with your Git identity and your own logins."
    tools_wizard
  else
    tools_run "${want[@]}"
  fi
}

# At the first interactive login, after the welcome: offer the wizard once.
# Sets TOOLS_OFFERED=yes if the wizard ran.
TOOLS_OFFERED=no
tools_offer() {
  local mark="$HOME/.config/onbehalf/tools-offered" id todo=no
  [ ! -e "$mark" ] || return 0
  tools_terminal || return 0
  tools_refusal >/dev/null && return 0
  (
    umask 077
    mkdir -p "${mark%/*}"
    set -C
    : >"$mark"
  ) 2>/dev/null || return 0
  tools_load
  for id in "${TOOL_IDS[@]}"; do
    tool_state "$id"
    case $TOOL_STATE in todo | warn) todo=yes ;; esac
  done
  tools_save
  [ "$todo" = yes ] || return 0
  TOOLS_OFFERED=yes
  trap tools_interrupted INT
  section "Work tools" "first login"
  say "The runtime works as you: with your Git identity and your own logins."
  say "Select the tools to set up now. You can come back at any time: ${_b}onbehalf tools${_0}"
  tools_wizard
}

# The checklist of every tool, then the selected setups and the summary.
tools_wizard() {
  local i id n=${#TOOL_IDS[@]}
  MENU_LABEL=() MENU_STATE=() MENU_HELP=() MENU_ON=() MENU_OFF=()
  tools_headings MENU_HEAD
  for ((i = 0; i < n; i++)); do
    id=${TOOL_IDS[i]}
    tool_state "$id"
    MENU_LABEL[i]=${TOOL_LABEL[$id]}
    MENU_HELP[i]=${TOOL_HELP[$id]}
    MENU_ON[i]=0 MENU_OFF[i]=0
    case $TOOL_STATE in
      ok) MENU_STATE[i]="$_g✓ $TOOL_BRIEF$_0" ;;
      warn) MENU_STATE[i]="$_y! $TOOL_BRIEF$_0" MENU_ON[i]=1 ;;
      missing) MENU_STATE[i]=$(tools_missing_hint) MENU_OFF[i]=1 ;;
      *) MENU_STATE[i]="$_y$TOOL_BRIEF$_0" MENU_ON[i]=1 ;;
    esac
  done
  printf '\n'
  if ! menu_checklist; then
    printf '\n'
    note "Nothing changed. To set up your work tools later: onbehalf tools"
    return 0
  fi
  local want=()
  for ((i = 0; i < n; i++)); do [ "${MENU_ON[i]}" = 0 ] || want+=("${TOOL_IDS[i]}"); done
  tools_run "${want[@]}"
}

# tools_run ID...: set up these tools, then show every tool in the summary.
tools_run() {
  declare -A result=() detail=()
  local id k=0 rc title
  for id in "$@"; do
    k=$((k + 1))
    title=$(tool_title "$id")
    tool_state "$id"
    if [ "$TOOL_STATE" = missing ]; then
      section "$title" "step $k of $#"
      printf '  %s!%s %s: %s\n' "$_y" "$_0" "$title" "$(tools_missing_hint)"
      continue
    fi
    section "$title" "step $k of $#"
    rc=0
    "${TOOL_HANDLER[$id]}_setup" ${TOOL_ARG[$id]:+"${TOOL_ARG[$id]}"} || rc=$?
    tool_state "$id"
    case $rc in
      0)
        if [ "$TOOL_STATE" = ok ]; then
          result[$id]=ok detail[$id]="$TOOL_DETAIL (set now)"
          printf '\n  %s✓%s %s: %s\n' "$_g" "$_0" "$title" "$TOOL_DETAIL"
        else
          result[$id]=fail detail[$id]="not finished: $TOOL_DETAIL"
          printf '\n  %s!%s %s: %s\n' "$_y" "$_0" "$title" "$TOOL_DETAIL"
        fi
        ;;
      3) result[$id]=kept detail[$id]="$TOOL_DETAIL (kept)" ;;
      130)
        result[$id]=fail detail[$id]="cancelled"
        printf '\n  %s!%s %s: cancelled\n' "$_y" "$_0" "$title"
        ;;
      *)
        result[$id]=fail detail[$id]="did not finish: $TOOL_DETAIL"
        printf '\n  %s!%s %s: did not finish\n' "$_y" "$_0" "$title"
        ;;
    esac
  done
  tools_summary
}

# The summary of every tool: from result/detail of tools_run, else the state.
tools_summary() {
  local i id total=0 ready=0 retry=() glyph text label head=()
  local lines=()
  tools_headings head
  for ((i = 0; i < ${#TOOL_IDS[@]}; i++)); do
    id=${TOOL_IDS[i]}
    if [ -n "${head[i]:-}" ]; then
      [ "$i" = 0 ] || lines+=("")
      lines+=("  $_d${head[i]}$_0")
    fi
    label=$(printf '%-16s' "${TOOL_LABEL[$id]}")
    if [ -n "${result[$id]:-}" ]; then
      case ${result[$id]} in ok | kept) glyph="$_g✓$_0" ;; *) glyph="$_r✗$_0" ;; esac
      text=${detail[$id]}
      [ "${result[$id]}" != fail ] || retry+=("$id")
    else
      tool_state "$id"
      case $TOOL_STATE in
        ok) glyph="$_g✓$_0" text=$TOOL_DETAIL ;;
        missing) glyph="$_y!$_0" text=$(tools_missing_hint) ;;
        *)
          glyph="$_d○$_0" text="$TOOL_DETAIL"
          retry+=("$id")
          ;;
      esac
      result[$id]=$TOOL_STATE
    fi
    [ "${result[$id]}" = missing ] || total=$((total + 1))
    case ${result[$id]} in ok | kept) ready=$((ready + 1)) ;; esac
    lines+=("  $glyph $label $text")
    case ${result[$id]} in
      ok | kept) TOOL_SEEN[$id]=ok ;;
      missing | warn) TOOL_SEEN[$id]=${result[$id]} ;;
      *) TOOL_SEEN[$id]=todo ;;
    esac
  done
  tools_save
  local what="work tools"
  [ ${#head[@]} = 0 ] || what="work tools and MCP connections"
  if [ "$ready" = "$total" ]; then
    menu_box "$_g" "✓ Your $what are ready"
  else
    menu_box "$_y" "$ready of $total $what ready"
  fi
  printf '%s\n' "${lines[@]}"
  printf '\n'
  [ ${#retry[@]} = 0 ] || printf '  %sFinish later:%s onbehalf tools %s\n' "$_d" "$_0" "${retry[*]}"
  printf '  %sStart the AI harness:%s %s\n' "$_d" "$_0" "$(harness command)"
}

# For onbehalf report: one line per work tool, ID and state, tab-separated.
# No prompts and no terminal needed.
tools_list() {
  local id
  [ ! -r "$ONBEHALF_ETC/onbehalf.conf" ] || load_conf
  tools_load
  for id in "${TOOL_IDS[@]}"; do
    tool_state "$id"
    printf '%s\t%s\n' "$id" "$TOOL_STATE"
  done
  tools_save
}

# For onbehalf status: one line per work tool.
tools_status() {
  local id
  tools_load
  for id in "${TOOL_IDS[@]}"; do
    tool_state "$id"
    case $TOOL_STATE in
      ok) ok "$(tool_title "$id"): $TOOL_DETAIL" ;;
      missing) info "$(tool_title "$id"): not installed on this host" ;;
      *)
        warn "$(tool_title "$id"): $TOOL_DETAIL"
        fix "onbehalf tools $id"
        ;;
    esac
  done
  tools_save
}

for _tool in "$ONBEHALF_LIB"/tools/*.sh; do
  # shellcheck source=/dev/null
  . "$_tool"
done
unset _tool
# The tools of onbehalf itself. A tool of the shared stack cannot replace one.
TOOL_BUILTIN=("${TOOL_IDS[@]}")
