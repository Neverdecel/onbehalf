# shellcheck shell=bash disable=SC2154 # colours come from ui.sh
# Interactive host setup and a short login message. Reuse the operator commands.

cmd_setup() {
  need_root
  [ $# = 0 ] || die "usage: onbehalf setup"
  [ -t 0 ] && [ -t 1 ] || die "setup must have a terminal. For scripts, use the operator commands"
  local answer dir names=() name accounts users access=skip

  heading "onbehalf host setup"
  info "Roles:"
  info "  You are the host administrator. You run this wizard as root."
  info "  Users are usual accounts, without sudo or docker. Each user gets a personal gateway key."
  info "Credentials:"
  info "  Model provider keys (for example Azure AI Foundry) stay in the gateway. onbehalf never asks for them."
  info "  onbehalf asks for the admin key of the gateway (LITELLM_MASTER_KEY) to make the personal keys."
  info "  Users log in to Azure, GitHub and other tools themselves."
  info "This wizard does not install OpenCode or the gateway. It keeps the credentials and personal settings that the host has."
  ask answer "Start host setup? (yes/no)" no
  [ "$answer" = yes ] || return 0

  heading "Prerequisites"
  setup_prerequisites || {
    setup_paused
    return 1
  }

  heading "1. Model gateway"
  if [ -r "$ONBEHALF_ETC/onbehalf.conf" ]; then
    info "The wizard keeps the current gateway connection. To change it, use 'onbehalf init'."
  else
    (cmd_init) || {
      setup_paused
      return 1
    }
  fi
  load_conf

  heading "2. Shared setup"
  if [ -e "$ONBEHALF_STACK/current" ]; then
    info "Keep the installed stack."
  else
    info "Use a stack source from the Git repository of your team. The team must review it."
    info "The models in the stack must already be on the gateway. Do not include credentials."
    ask dir "Reviewed stack source"
    [ -r "$dir/opencode/opencode.json" ] || die "the directory must contain opencode/opencode.json"
    jq -e 'type == "object"' "$dir/opencode/opencode.json" >/dev/null || die "the configuration of the stack source must be a JSON object"
    ask answer "Install this directory for all users? (yes/no)" no
    [ "$answer" = yes ] || return 0
    cmd_stack_install --no-restart "$dir"
  fi

  heading "3. Users"
  enroll_conf
  if [ "$ONBEHALF_AUTO_ENROLL" = yes ]; then
    info "Keep auto-enroll: onbehalf enrolls each user who can log in through SSH at the first login."
  else
    local default=no
    if grep -qs aad /etc/nsswitch.conf; then
      info "This host uses the Entra login of Azure: access to the VM decides who logs in."
      default=yes
    fi
    info "With auto-enroll, onbehalf enrolls each user who can log in through SSH at the first login."
    info "onbehalf never enrolls administrators (sudo). Then the login permission is the only access decision."
    ask answer "Turn on auto-enroll? (yes/no)" "$default"
    if [ "$answer" = yes ]; then
      (cmd_auto_enroll on) || {
        setup_paused
        return 1
      }
    fi
  fi
  info "You can also add accounts by name."
  info "Do not add the host administrator as a user."
  info "You can use accounts that the host has. The wizard keeps their personal settings."
  info "The account must have an SSH login."
  ask accounts "Account names, separated by spaces (Enter to skip)"
  read -r -a names <<<"$accounts"
  if [ ${#names[@]} -gt 0 ]; then
    for name in "${names[@]}"; do
      if id "$name" >/dev/null 2>&1; then
        user_name_valid "$name" || die "invalid account name: $name"
        [ "$(id -u "$name")" -ge 1000 ] || die "$name is a system account"
        [ -z "$(privileged_groups_of "$name")" ] || die "$name is in groups with privileges. Select a usual account"
      else
        account_name_valid "$name" || die "invalid account name: $name"
      fi
    done
    ask answer "Add these users? (yes/no)" no
    [ "$answer" = yes ] || return 0
    (cmd_user_add "${names[@]}")
  fi

  heading "4. Check the host"
  (
    # shellcheck disable=SC2034 # read by the doctor output helpers
    UI_ERRORS=0 UI_WARNINGS=0
    cmd_doctor
  )

  heading "5. Model access"
  info "The host checks do not show that the model provider answers."
  info "A provider can refuse every request, for example because of a network rule."
  mapfile -t users < <(people)
  if [ ${#users[@]} = 0 ]; then
    info "No users yet. Check later: sudo onbehalf doctor --model-check"
  else
    ask answer "Send one short test request as ${users[0]}? It is model use of ${users[0]}. (yes/no)" no
    if [ "$answer" = yes ]; then
      if (doctor_model_access "${users[0]}" ""); then access=ok; else access=fail; fi
    fi
  fi

  heading "Result"
  result ok "host configuration: passed"
  case $access in
    ok) result ok "model access: the model answered" ;;
    fail)
      result fail "model access: the model did not answer"
      info "Fix the problem above, then check again: sudo onbehalf doctor --model-check"
      return 1
      ;;
    *) result skip "model access: not checked. Check later: sudo onbehalf doctor --model-check" ;;
  esac
  ok "Host setup is complete. Users can connect through SSH and run opencode."
  info "Users make their own changes without root. See the user guide."
}

# OpenCode and a running gateway must be there before the wizard changes
# anything. Returns 1, with the steps to take, if one is missing.
setup_prerequisites() {
  local oc ready=yes answer
  if oc=$(command -v opencode) && [[ $oc != /home/* && $oc != /root/* ]]; then
    ok "OpenCode is installed for the full host"
  else
    err "OpenCode is not installed for the full host"
    fix "install OpenCode with the OpenCode documentation. See the operator guide, section 'OpenCode'"
    ready=no
  fi

  if [ -r "$ONBEHALF_ETC/onbehalf.conf" ]; then
    load_conf
    if curl -fsS --max-time 10 "$ONBEHALF_GATEWAY_URL/health/liveliness" >/dev/null 2>&1; then
      ok "gateway $ONBEHALF_GATEWAY_URL answers"
    else
      err "gateway $ONBEHALF_GATEWAY_URL does not answer"
      fix "start the gateway. See the operator guide, section 'Model gateway'"
      ready=no
    fi
  else
    info "The model gateway is LiteLLM with a PostgreSQL database and one or more models."
    ask answer "Does the gateway run, and do you have its URL and admin key? (yes/no)" no
    if [ "$answer" = yes ]; then
      ok "the gateway is ready; the next step checks it"
    else
      err "the model gateway is not ready"
      gateway_guide
      ready=no
    fi
  fi
  [ "$ready" = yes ]
}

setup_paused() {
  heading "Setup paused"
  info "The completed steps stay. Nothing else changed."
  info "Correct the problem above. Then continue with: sudo onbehalf setup"
}

cmd_login() {
  [ $# = 0 ] || die "usage: onbehalf login"
  # No output or prompts for SSH commands, file transfers or internal runuser calls.
  [ -t 0 ] && [ -t 1 ] || return 0
  if [ -r "$ONBEHALF_ETC/onbehalf.conf" ]; then
    load_conf
  fi
  if [ ! -r "$ONBEHALF_ETC/onbehalf.conf" ] || [ ! -e "${ONBEHALF_STACK:-/opt/onbehalf/stack}/current" ]; then
    if [ "$(id -u)" = 0 ]; then
      cmd_setup "$@"
    else
      heading "onbehalf host setup is not complete"
      info "An administrator must run: sudo onbehalf setup"
    fi
    return 0
  fi
  [ "$(id -u)" != 0 ] || return 0
  if is_operator "$(id -un)"; then
    if operator_runs_opencode "$(id -un)"; then
      warn "OpenCode runs in this operator account. Stop it: opencode service stop"
    fi
    if [ -e "$HOME/.config/onbehalf/operator-seen" ]; then
      if [ -n "$(agent_of "$(id -un)")" ]; then
        info "onbehalf operator account: no runtime here. Your runtime account: sudo onbehalf operator shell"
      else
        info "onbehalf operator account: no runtime here. To get one: sudo onbehalf operator add --runtime $(id -un)"
      fi
      return 0
    fi
    heading "onbehalf operator"
    info "You manage onbehalf for this host: sudo onbehalf doctor"
    info "Operators run no runtime in this account, because a runtime here can use sudo."
    if [ -n "$(agent_of "$(id -un)")" ]; then
      info "Open your runtime account: sudo onbehalf operator shell"
    else
      info "To get a runtime too: sudo onbehalf operator add --runtime $(id -un)"
    fi
    (
      umask 077
      mkdir -p "$HOME/.config/onbehalf"
      : >"$HOME/.config/onbehalf/operator-seen"
    ) 2>/dev/null || :
    return 0
  fi
  if [ ! -s "$HOME/.config/onbehalf/gateway.key" ]; then
    enroll_conf
    if [ "$ONBEHALF_AUTO_ENROLL" = yes ]; then
      info "onbehalf did not set up your account at this login. onbehalf does not enroll administrator accounts."
      info "Otherwise log in again. If that does not help, ask the operator to run: sudo onbehalf user enroll $(id -un)"
    else
      info "Ask the operator to add your account to onbehalf."
    fi
    return 0
  fi
  # The last login of this user, for onbehalf report.
  (
    umask 077
    : >"$HOME/.config/onbehalf/last-login"
  ) 2>/dev/null || :
  local stack_changed=no
  login_stack_seen || stack_changed=yes
  if [ -e "$HOME/.config/onbehalf/welcome-seen" ]; then
    # The wizard ends with its own summary; the short message would repeat it.
    tools_offer
    [ "$TOOLS_OFFERED" = yes ] || login_panel "$stack_changed"
    return 0
  fi
  if [ ! -e "$HOME/.config/onbehalf/welcome-seen" ]; then
    heading "onbehalf"
    info "Start the AI harness: opencode"
    [ -z "$(owner_of "$(id -un)")" ] \
      || info "This is the runtime account of $(owner_of "$(id -un)"). The logins that you make here stay in this account."
    info "Set up your work tools and logins at any time: onbehalf tools"
    info "Model access is ready. Do not add a personal model key."
    info "Change your own settings, custom agents, skills and tools without root."
    info "User guide: $ONBEHALF_SHARE/docs/user-guide.md"
    info "For problems, run: onbehalf status"
    (
      umask 077
      set -C
      : >"$HOME/.config/onbehalf/welcome-seen"
    ) 2>/dev/null || :
  fi
  tools_offer
}

# Every later login of a user: a short message with what matters now.
# Local reads only, so a login never waits on the network.
login_panel() {
  local owner todo
  owner=$(owner_of "$(id -un)")
  todo=$(tools_unfinished)
  printf '\n%sonbehalf%s · start the AI harness: opencode\n' "$_b" "$_0"
  [ -z "$owner" ] || info "This is the runtime account of $owner. The logins that you make here stay in this account."
  [ "$1" = no ] || info "The shared stack changed after your last login: new team settings, custom agents, skills or work tools."
  [ -z "$todo" ] || printf '  %s!%s Work tools to finish: onbehalf tools %s\n' "$_y" "$_0" "$todo"
  info "Problems: onbehalf status · User guide: $ONBEHALF_SHARE/docs/user-guide.md"
  tools_refresh_later
}

# Note the shared stack release of this login. False if it changed since the
# last noted login; the first note is true, as there is nothing to compare.
login_stack_seen() {
  local mark="$HOME/.config/onbehalf/stack-seen" now before=""
  now=$(link_of "${ONBEHALF_STACK:-/opt/onbehalf/stack}/current")
  [ ! -r "$mark" ] || before=$(<"$mark")
  [ "$before" = "$now" ] && return 0
  (
    umask 077
    printf '%s\n' "$now" >"$mark"
  ) 2>/dev/null || :
  [ -z "$before" ]
}
