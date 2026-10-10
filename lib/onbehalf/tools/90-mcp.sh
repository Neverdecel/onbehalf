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

TOOLS_DISCOVER+=(tool_mcp_discover)

tool_mcp_config() { echo "${ONBEHALF_STACK:-/opt/onbehalf/stack}/current/opencode/opencode.json"; }

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
  # OpenCode connects again after the login; wait for it.
  for ((i = 0; i < 15; i++)); do
    tool_mcp_state "$name"
    [ "$TOOL_STATE" != ok ] || break
    unset TOOL_MCP_LIST
    sleep 1
  done
}
