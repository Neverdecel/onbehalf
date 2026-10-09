# shellcheck shell=bash disable=SC2034,SC2154 # TOOL_* is read by tools.sh; colours come from ui.sh
# Work tool: the GitHub CLI, logged in with the user's own GitHub account.

tool_register gh "GitHub CLI" "Your own GitHub login, for repositories, issues and pull requests."

tool_gh_state() {
  if ! command -v gh >/dev/null; then
    TOOL_STATE=missing TOOL_DETAIL="not installed"
    return 0
  fi
  local out
  if out=$(gh auth status 2>&1); then
    TOOL_STATE=ok TOOL_DETAIL="logged in"
    [[ $out =~ account\ ([^[:space:]]+) ]] && TOOL_DETAIL="logged in as ${BASH_REMATCH[1]}"
    TOOL_BRIEF=${TOOL_DETAIL#logged in as }
  else
    TOOL_STATE=todo TOOL_DETAIL="not logged in"
  fi
}

tool_gh_setup() {
  say "Log in with your own GitHub account. The login stays private to you."
  note "Now the usual GitHub login: gh auth login"
  printf '\n'
  tool_native gh auth login
}
