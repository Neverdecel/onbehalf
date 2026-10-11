# shellcheck shell=bash
# onbehalf doctor: check the host and every user, with a fix for each
# problem. Exit code 1 if there is an error. Also useful on a host that was
# set up before onbehalf: it shows what still breaks the core claim.
# With --model-check, also send one short model request as a user: host
# checks pass even when the model provider refuses every request.

REQUIRED_TOOLS="curl jq git runuser getent useradd usermod userdel pkill pgrep"

cmd_doctor() {
  need_root
  local check_model=no user="" model=""
  while [ $# -gt 0 ]; do
    case $1 in
      --model-check)
        check_model=yes
        shift
        ;;
      --user | --person | --model)
        [ -n "${2:-}" ] || die "give a value for $1"
        if [ "$1" != --model ]; then user=$2; else model=$2; fi
        check_model=yes
        shift 2
        ;;
      *) die "usage: onbehalf doctor [--model-check] [--user NAME] [--model MODEL]" ;;
    esac
  done

  heading "Host"
  doctor_host || {
    summary
    exit 1
  }

  heading "Users"
  local u n=0
  for u in $(people); do
    n=$((n + 1))
    heading "$u"
    doctor_user "$u"
  done
  if [ "$n" = 0 ]; then
    enroll_conf
    if [ "$ONBEHALF_AUTO_ENROLL" = yes ]; then
      info "no users yet. onbehalf enrolls each user at the first login"
    else
      warn "no users yet"
      fix "sudo onbehalf user add NAME..., or enroll users at login: sudo onbehalf auto-enroll on"
    fi
  fi
  doctor_other_accounts

  local host_errors=$UI_ERRORS host_warnings=$UI_WARNINGS access=skip
  heading "Model access"
  if [ "$check_model" = yes ]; then
    if doctor_model_access "$user" "$model"; then access=ok; else access=fail; fi
  else
    info "not checked: the checks above send no model requests"
    info "to send one short request as a user: sudo onbehalf doctor --model-check"
  fi

  heading "Result"
  if [ "$host_errors" = 0 ]; then
    result ok "host configuration: no errors, $host_warnings warning(s)"
  else
    result fail "host configuration: $host_errors error(s), $host_warnings warning(s)"
  fi
  case $access in
    ok) result ok "model access: the model answered" ;;
    fail) result fail "model access: the model did not answer" ;;
    *) result skip "model access: not checked" ;;
  esac
  [ "$UI_ERRORS" = 0 ] || exit 1
}

# doctor_model_access [USER] [MODEL]: one model request with the key of a
# user (default: the first user) to a model of the catalog (default: the stack
# default). Returns 1 if it fails.
doctor_model_access() {
  local u=$1 model=$2 users p found=no
  mapfile -t users < <(people)
  [ -n "$u" ] || u=${users[0]:-}
  for p in "${users[@]}"; do
    if [ "$p" = "$u" ]; then found=yes; fi
  done
  if [ -z "$u" ]; then
    err "no user to send the request as"
    fix "sudo onbehalf user add NAME, then check again"
    return 1
  elif [ "$found" = no ]; then
    err "$u is not a user on this host"
    fix "use one of: ${users[*]}"
    return 1
  fi
  if [ -z "$model" ] && ! model=$(stack_default_model "$ONBEHALF_STACK/current" 2>/dev/null); then
    err "the shared stack has no model to check"
    fix "sudo onbehalf stack install <reviewed stack source>"
    return 1
  fi
  model_access_check "$(home_of "$u")/.config/onbehalf/gateway.key" "$model" "$u"
}

# Returns 1 if the host is not set up, so user checks make no sense.
doctor_host() {
  . /etc/os-release
  case $ID in
    ubuntu | arch) ok "$PRETTY_NAME" ;;
    *) warn "$PRETTY_NAME is not tested. onbehalf supports Ubuntu and Arch" ;;
  esac

  local t missing=
  for t in $REQUIRED_TOOLS; do command -v "$t" >/dev/null || missing="$missing $t"; done
  if [ -z "$missing" ]; then
    ok "required tools are installed"
  else
    err "missing tools:$missing"
    fix "run the installer again with --install-deps"
  fi

  # The configuration names the AI harness of the host.
  [ ! -r "$ONBEHALF_ETC/onbehalf.conf" ] || load_conf
  local cmd label path
  cmd=$(harness command) label=$(harness label)
  if path=$(command -v "$cmd"); then
    case $path in
      /home/* | /root/*) warn "$label at $path is a personal installation, not an installation for the full host" ;;
      *) ok "$("$cmd" --version 2>/dev/null) at $path" ;;
    esac
  else
    err "$label is not installed for the full host"
    fix "install $label for the full host with the $label documentation. See the operator guide, section '$label'"
  fi

  if [ ! -r "$ONBEHALF_ETC/onbehalf.conf" ]; then
    err "this host is not connected to a gateway"
    fix "sudo onbehalf init"
    return 1
  fi
  load_conf

  if [ "$(stat -c '%a %U' "$ONBEHALF_ETC/gateway-admin.key" 2>/dev/null || true)" = "600 root" ]; then
    ok "only root can read the admin key of the gateway"
  else
    err "the admin key of the gateway is missing, or other accounts can read it"
    fix "chmod 600 $ONBEHALF_ETC/gateway-admin.key && chown root: $ONBEHALF_ETC/gateway-admin.key"
  fi
  if curl -fsS --max-time 10 "$ONBEHALF_GATEWAY_URL/health/liveliness" >/dev/null 2>&1; then
    ok "gateway $ONBEHALF_GATEWAY_URL answers"
    local missing
    missing=$(gateway_api_missing)
    if [ -z "$missing" ]; then
      ok "the gateway serves the API of $label"
    else
      err "the gateway does not serve the API of $label: ${missing//$'\n'/ }"
      fix "use a LiteLLM version that serves these routes. See the operator guide, section 'Model gateway'"
    fi
    if gateway_admin GET "/key/list?size=1" >/dev/null 2>&1; then
      ok "the gateway accepts the admin key"
      # Operators see usage, not content: onbehalf report never shows it.
      if gateway_admin GET "/config/field/info?field_name=store_prompts_in_spend_logs" 2>/dev/null \
        | jq -e '.field_value == true' >/dev/null; then
        warn "the gateway keeps the questions of users and the answers of the model in its cost logs"
        fix "set general_settings.store_prompts_in_spend_logs: false in the gateway configuration"
      fi
    else
      err "the gateway does not accept the admin key"
      fix "sudo onbehalf init"
    fi
  else
    err "gateway $ONBEHALF_GATEWAY_URL does not answer"
    fix "start the gateway. See the operator guide, section 'Model gateway'"
  fi

  if [ -e "$ONBEHALF_STACK/current" ]; then
    ok "shared stack $(basename "$(readlink "$ONBEHALF_STACK/current")")"
    local problem
    problem=$(harness stack_problem)
    if [ -z "$problem" ]; then
      ok "the shared stack permits only its gateway providers"
    else
      warn "${problem%%$'\n'*}"
      fix "${problem#*$'\n'}"
    fi
    local loose
    loose=$(find "$ONBEHALF_STACK" \( ! -user root -o -perm -o+w -o -perm -g+w \) ! -type l -print -quit)
    if [ -n "$loose" ]; then
      err "users can change the shared stack ($loose)"
      fix "chown -R root: $ONBEHALF_STACK && chmod -R go-w $ONBEHALF_STACK"
    fi
  else
    err "no shared stack"
    fix "sudo onbehalf stack install DIR"
  fi

  enroll_check
  health_check
  operator_check
  [ -z "$(entra_group)" ] || ok "users follow the Entra group $(entra_group)"
  # The map decides who sync adds and removes; users must not change it.
  if [ -e "$ENTRA_MAP" ] && [ "$(stat -c '%a %U' "$ENTRA_MAP")" != "644 root" ]; then
    err "the Entra links in $ENTRA_MAP have the wrong owner or mode"
    fix "chown root: $ENTRA_MAP && chmod 644 $ENTRA_MAP"
  fi

  if grep -qE '^proc /proc proc .*hidepid=' /proc/mounts; then
    ok "/proc hides the processes of other accounts"
  else
    warn "/proc shows every process and command line to every account"
    fix "add 'proc /proc proc defaults,hidepid=invisible 0 0' to /etc/fstab, then: mount -o remount /proc"
  fi
  local ptrace
  ptrace=$(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || echo none)
  case $ptrace in
    none) info "kernel.yama.ptrace_scope is not available" ;;
    0)
      warn "kernel.yama.ptrace_scope is 0: a process can debug each other process of the same account"
      fix "echo 'kernel.yama.ptrace_scope = 1' > /etc/sysctl.d/60-onbehalf.conf && sysctl --system"
      ;;
    *) ok "kernel.yama.ptrace_scope is $ptrace" ;;
  esac
}

doctor_user() {
  local u=$1 home key groups
  home=$(home_of "$u")
  key="$home/.config/onbehalf/gateway.key"

  if [ "$(stat -c %a "$home")" = 700 ]; then
    ok "home directory is private"
  else
    err "other accounts can read the home directory $home ($(stat -c %a "$home"))"
    fix "chmod 700 $home"
  fi

  if [ "$(stat -c '%a %U' "$key" 2>/dev/null || true)" = "600 $u" ]; then
    ok "gateway key is private"
  else
    err "gateway key has the wrong owner or mode ($(stat -c '%a %U' "$key"))"
    fix "chown $u: $key && chmod 600 $key"
  fi
  if gateway_call "$key" GET /v1/models >/dev/null 2>&1; then
    ok "gateway key works"
  else
    err "the gateway does not accept the key of $u"
    fix "rm $key && sudo onbehalf user add $u"
  fi

  harness check "$u" "$home"

  local models policy=models
  ! models=$(stack_models "$ONBEHALF_STACK/current" 2>/dev/null) \
    || policy=$(gateway_key_policy "$u" "$models")
  if [ "$policy" = ok ]; then
    ok "gateway key permits only the model catalog and inference routes"
  elif [ "$policy" = routes ]; then
    warn "the gateway key of $u has the routes of an older onbehalf, so $u cannot see their own model use"
    fix "sudo onbehalf stack install --no-restart <stack source>   (updates every key, restarts nothing)"
  else
    err "the gateway key policy is not the same as the model catalog"
    fix "sudo onbehalf stack install <reviewed stack source>"
  fi

  local owner
  owner=$(owner_of "$u")
  [ -z "$owner" ] || ok "runtime account of the operator $owner"

  local entra
  entra=$(entra_id_of "$u")
  [ -z "$entra" ] || ok "linked to Entra account $(entra_upn_of "$u" | grep . || echo "$entra")"

  groups=$(privileged_groups_of "$u")
  if [ -n "$groups" ]; then
    err "$u is in the group(s) $groups, so $u can act as other users"
    fix "gpasswd -d $u <group>   (for each group)"
  fi
}

# Login accounts that are not users, for example an old shared account.
doctor_other_accounts() {
  local name uid shell others=
  while IFS=: read -r name _ uid _ _ _ shell; do
    if [ "$uid" -ge 1000 ] && [ "$uid" -lt 60000 ] && [[ $shell != */nologin && $shell != */false ]] \
      && ! grep -qx "$name" <<<"$(people)"; then
      others="$others $name"
    fi
  done < <(getent passwd)
  if [ -n "$others" ]; then
    heading "Other login accounts"
    warn "not onbehalf users:$others"
    fix "add real users with 'sudo onbehalf user add', and disable shared accounts"
  fi
}
