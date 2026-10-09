# shellcheck shell=bash disable=SC2034,SC2154 # TOOL_* is read by tools.sh; colours come from ui.sh
# Work tool: the Azure CLI, logged in as the user's own (Entra) account.

tool_register az "Azure CLI" "Your own Azure login. For a linked user, your Entra account."

# The account the Azure CLI is logged in as, if any.
tool_az_user() { az account show --query user.name -o tsv 2>/dev/null; }

tool_az_state() {
  if ! command -v az >/dev/null; then
    TOOL_STATE=missing TOOL_DETAIL="not installed"
    return 0
  fi
  local user upn
  if ! user=$(tool_az_user) || [ -z "$user" ]; then
    TOOL_STATE=todo TOOL_DETAIL="not logged in"
    return 0
  fi
  upn=$(tools_upn)
  if [ -n "$upn" ] && [ "${user,,}" != "${upn,,}" ]; then
    TOOL_STATE=warn TOOL_DETAIL="logged in as $user, not as your Entra account $upn"
    TOOL_BRIEF="$user (not your Entra account)"
  else
    TOOL_STATE=ok TOOL_DETAIL="logged in as $user" TOOL_BRIEF=$user
  fi
}

tool_az_setup() {
  local upn user pick acct
  upn=$(tools_upn)
  tool_az_state
  if [ "$TOOL_STATE" = warn ]; then
    user=$(tool_az_user)
    printf '  %s!%s Logged in as %s\n' "$_y" "$_0" "$user"
    say "  This is not your Entra account $upn."
    printf '\n'
    menu_choice pick "Log out, then log in as $upn" "Keep $user"
    [ "$pick" = 0 ] || return 3
    az logout >/dev/null 2>&1 || true
    note "logged out $user"
  fi
  say "Log in with your own work account${upn:+: $_b$upn$_0}."
  note "Now the usual Azure login: az login --use-device-code"
  printf '\n'
  tool_native az login --use-device-code -o none || return $?
  printf '\n'
  acct=$(az account show -o json 2>/dev/null) || return 1
  user=$(jq -r '.user.name // empty' <<<"$acct")
  ok "Logged in as $user"
  note "tenant $(jq -r '.tenantDisplayName // .tenantId // "?"' <<<"$acct") · subscription $(jq -r '.name // "?"' <<<"$acct")"
  if [ -n "$upn" ]; then
    if [ "${user,,}" = "${upn,,}" ]; then
      ok "This is your Entra account."
      return 0
    fi
    printf '  %s!%s This is not your Entra account %s.\n\n' "$_y" "$_0" "$upn"
    menu_choice pick "Log out again" "Keep $user"
    [ "$pick" = 0 ] || return 3
  else
    printf '\n'
    say "Must the runtime use this account?"
    menu_choice pick "Yes, use $user" "No, log out"
    [ "$pick" = 1 ] || return 0
  fi
  az logout >/dev/null 2>&1 || true
  return 1
}
