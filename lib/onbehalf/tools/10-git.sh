# shellcheck shell=bash disable=SC2034,SC2154 # TOOL_* is read by tools.sh; colours come from ui.sh
# Work tool: the Git identity in every commit, also the agent's commits.

tool_register git "Git" "Your name and email in commits, also in the commits of your runtime."

tool_git_state() {
  if ! command -v git >/dev/null; then
    TOOL_STATE=missing TOOL_DETAIL="not installed"
    return 0
  fi
  local name email
  name=$(git config --global user.name || true)
  email=$(git config --global user.email || true)
  if [ -n "$name" ] && [ -n "$email" ]; then
    TOOL_STATE=ok TOOL_DETAIL="$name <$email>"
  else
    TOOL_STATE=todo TOOL_DETAIL="no identity" TOOL_BRIEF="not set"
  fi
}

tool_git_setup() {
  local name email upn
  say "Git puts a name and email in each commit: your commits and the commits of your runtime."
  note "onbehalf keeps it for your account only (git config --global)."
  printf '\n'
  name=$(git config --global user.name || true)
  [ -n "$name" ] || name=$(tools_full_name)
  while :; do
    menu_input name "Name" "$name"
    [ -z "$name" ] || break
    printf '  %s!%s give a name\n' "$_y" "$_0"
  done
  email=$(git config --global user.email || true)
  upn=$(tools_upn)
  if [ -z "$email" ] && [ -n "$upn" ]; then
    email=$upn
    note "Proposed: your Entra account. If your mail address is different, change it."
  fi
  while :; do
    menu_input email "Email" "$email"
    [[ $email =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] && break
    printf '  %s!%s that is not an email address\n' "$_y" "$_0"
  done
  git config --global user.name "$name" && git config --global user.email "$email"
}
