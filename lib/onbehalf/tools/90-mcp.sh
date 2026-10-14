# shellcheck shell=bash disable=SC2034,SC2154 # TOOL_* is read by tools.sh; colours come from ui.sh
# Work tools: the MCP servers of the shared stack that need the user's own
# login. Each remote server with OAuth (not "oauth": false, no fixed
# Authorization header) becomes a tool, mcp:NAME. The login is OpenCode's own:
# opencode mcp auth NAME. Its token stays in the user's OpenCode data.
#
# The OAuth login ends with the browser opening a callback address on
# 127.0.0.1 of this host. Over SSH that address is not reachable from the
# user's computer, so the user pastes it here and onbehalf opens it on
# this host, as the user.
#
# A shared server with "disabled": true stays off for a user until their
# login: OpenCode then shows no server that the user cannot use. After the
# login, onbehalf puts a copy of the server, turned on, in the personal
# opencode.jsonc. OpenCode does not merge a part of a server, so the copy is
# the full entry. ~/.config/onbehalf/mcp-on records the copies of onbehalf;
# each stack install updates them (onbehalf tools --sync).

TOOLS_DISCOVER+=(tool_mcp_discover)

tool_mcp_config() { echo "${ONBEHALF_STACK:-/opt/onbehalf/stack}/current/opencode/opencode.json"; }
tool_mcp_personal() { echo "$HOME/.config/opencode/opencode.jsonc"; }
tool_mcp_record() { echo "$HOME/.config/onbehalf/mcp-on"; }

# tool_mcp_write NAME...: in opencode.jsonc, a copy of each shared server that
# is off by default, turned on. A server that is not off by default, or not
# in the stack now, gets no copy. Fails if the file is not plain JSON.
tool_mcp_write() {
  local f tmp
  f=$(tool_mcp_personal)
  [ ! -L "$f" ] || return 1
  tmp=$(umask 077 && mktemp "$f.XXXXXX") || return 1
  if { cat "$f" 2>/dev/null || echo '{}'; } | jq --slurpfile s "$(tool_mcp_config)" '
    reduce $ARGS.positional[] as $n (.;
      ($s[0].mcp.servers[$n] // {}) as $e
      | if $e.disabled == true then .mcp.servers[$n] = $e + {disabled: false}
        else del(.mcp.servers[$n]) end)' --args "$@" >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$f"
  else
    rm -f "$tmp"
    return 1
  fi
}

# tool_mcp_on NAME: turn the server on for this user after the login. If
# opencode.jsonc is not plain JSON, show the user what to add.
tool_mcp_on() {
  local r names
  r=$(tool_mcp_record)
  [ "$(jq -r --arg n "$1" '.mcp.servers[$n].disabled' "$(tool_mcp_config)")" = true ] || return 0
  (
    umask 077
    mkdir -p "${r%/*}"
    { cat "$r" 2>/dev/null || :; } | grep -Fxv "$1" >"$r.new" || :
    echo "$1" >>"$r.new"
    mv -f "$r.new" "$r"
  )
  mapfile -t names <"$r"
  if tool_mcp_write "${names[@]}"; then
    (cd ~ && opencode service restart) >/dev/null 2>&1 || :
    return 0
  fi
  printf '\n  %s!%s Could not change %s. Add this to it:\n\n' "$_y" "$_0" "$(tool_mcp_personal)"
  jq --arg n "$1" '{mcp: {servers: {($n): (.mcp.servers[$n] + {disabled: false})}}}' "$(tool_mcp_config)" | sed 's/^/    /'
  printf '\n  Then: opencode service restart\n'
}

# For onbehalf stack install: update the copies to the current stack, and
# remove a copy when the stack has no such server now.
tool_mcp_sync() {
  local r names keep
  r=$(tool_mcp_record)
  [ -s "$r" ] || return 0
  mapfile -t names <"$r"
  tool_mcp_write "${names[@]}" || return 1
  keep=$(jq -r '.mcp.servers // {} | to_entries[] | select(.value.disabled == true) | .key' "$(tool_mcp_config)")
  grep -Fxf <(printf '%s\n' "$keep") "$r" >"$r.new" || :
  mv -f "$r.new" "$r"
}

# Names of the shared MCP servers that need a personal login.
tool_mcp_servers() {
  jq -r '.mcp.servers // {} | to_entries[]
    | select(.value.type == "remote" and .value.enabled != false and .value.oauth != false)
    | select((.value.headers // {}) | keys | map(ascii_downcase) | index("authorization") | not)
    | .key' "$(tool_mcp_config)" 2>/dev/null || true
}

tool_mcp_discover() {
  # The MCP logins use the commands of OpenCode.
  [ "$(harness_id)" = opencode ] || return 0
  local name url
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    url=$(jq -r --arg n "$name" '.mcp.servers[$n].url' "$(tool_mcp_config)")
    url=${url#*://}
    tool_register "mcp:$name" "$name" \
      "Lets the runtime use $name (${url%%/*}) with your own account." tool_mcp "$name"
  done < <(tool_mcp_servers)
}

# The output of opencode mcp list, read once. The OpenCode service connects to
# the servers after it starts, so wait until every shared server is listed.
tool_mcp_list() {
  [ -z "${TOOL_MCP_LIST+set}" ] || return 0
  local i out name all
  for ((i = 0; i < 15; i++)); do
    out=$(cd ~ && NO_COLOR=1 timeout 30 opencode mcp list 2>/dev/null) || out=''
    all=yes
    while IFS= read -r name; do
      [ -z "$name" ] || awk -v n="$name" '$2 == n { f = 1 } END { exit !f }' <<<"$out" || all=no
    done < <(tool_mcp_servers)
    [ "$all" = no ] || break
    sleep 1
  done
  TOOL_MCP_LIST=$out
}

tool_mcp_state() {
  if ! command -v opencode >/dev/null; then
    TOOL_STATE=missing TOOL_DETAIL="OpenCode is not installed"
    return 0
  fi
  local status
  tool_mcp_list
  status=$(awk -v n="$1" '$2 == n { $1 = ""; $2 = ""; sub(/^ +/, ""); print; exit }' <<<"$TOOL_MCP_LIST")
  case $status in
    connected) TOOL_STATE=ok TOOL_DETAIL="connected" ;;
    "needs authentication") TOOL_STATE=todo TOOL_DETAIL="not logged in" ;;
    # Off until the login. After a login it is off only if the copy failed.
    disabled)
      if grep -Fqx "$1" "$(tool_mcp_record)" 2>/dev/null; then
        TOOL_STATE=warn TOOL_DETAIL="logged in, but off in $(tool_mcp_personal)"
      else
        TOOL_STATE=todo TOOL_DETAIL="not logged in"
      fi
      ;;
    "") TOOL_STATE=todo TOOL_DETAIL="not connected" ;;
    *) TOOL_STATE=warn TOOL_DETAIL=$status ;;
  esac
}

tool_mcp_setup() {
  local name=$1 out pid url cb rc=0 i
  say "Log in with your own account. Then the runtime uses $name as you."
  note "Now the usual OpenCode login: opencode mcp auth $name"
  out=$(mktemp)
  (cd ~ && NO_COLOR=1 exec opencode mcp auth "$name") >"$out" 2>&1 </dev/null &
  pid=$!
  TOOL_CANCELLED=no
  trap 'TOOL_CANCELLED=yes; kill "$pid" 2>/dev/null' INT
  for ((i = 0; i < 300; i++)); do
    url=$(grep -oE 'https?://[^[:space:]]+' "$out" | head -1 || true)
    [ -z "$url" ] && kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if [ -n "$url" ]; then
    printf '\n  Open this address in your browser and log in:\n\n  %s%s%s\n\n' "$_c" "$url" "$_0"
    note "Then your browser opens an address on 127.0.0.1. Through SSH, it cannot open it:"
    note "copy the full address from the address bar and paste it here."
    printf '\n  %sAddress:%s ' "$_y" "$_0"
    while kill -0 "$pid" 2>/dev/null; do
      cb=''
      IFS= read -r -t 1 cb </dev/tty || {
        # A timeout is > 128; anything else means the terminal is gone.
        [ $? -gt 128 ] && continue
        kill "$pid" 2>/dev/null
        break
      }
      if [[ $cb =~ ^http://(127\.0\.0\.1|localhost):[0-9]+/ ]]; then
        # Through stdin: the address carries a one-time code; keep it out of ps.
        printf 'url = "%s"\n' "$cb" | curl -sS -o /dev/null --max-time 15 -K - 2>/dev/null \
          || printf '  %s!%s that address did not work. The login can be too old\n' "$_y" "$_0"
      elif [ -n "$cb" ]; then
        printf '  %s!%s paste the address that starts with http://127.0.0.1:\n' "$_y" "$_0"
      fi
      kill -0 "$pid" 2>/dev/null && printf '  %sAddress:%s ' "$_y" "$_0"
    done
  fi
  wait "$pid" || rc=$?
  trap tools_interrupted INT
  unset TOOL_MCP_LIST
  if [ "$TOOL_CANCELLED" = yes ]; then
    rm -f "$out"
    return 130
  fi
  if [ "$rc" != 0 ]; then
    printf '\n'
    grep -vE '^[[:space:]│┌└]*$' "$out" | sed 's/^[│■●◇┌└ ]*/  /' | tail -3
  fi
  rm -f "$out"
  [ "$rc" = 0 ] || return "$rc"
  tool_mcp_on "$name"
  # OpenCode connects again after the login; wait for it.
  for ((i = 0; i < 15; i++)); do
    tool_mcp_state "$name"
    [ "$TOOL_STATE" != ok ] || break
    unset TOOL_MCP_LIST
    sleep 1
  done
}
