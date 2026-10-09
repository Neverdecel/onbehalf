# shellcheck shell=bash
# onbehalf user add / remove: onboard and offboard users.

# Groups that let a user act as another user (sudo, docker) or read
# other users' logs (adm). Their members break the core claim. aad_admins:
# the Entra login of Azure VMs gives this group sudo (role VM Administrator Login).
# onbehalf-operators: may run onbehalf as root, so may change every agent.
PRIVILEGED_GROUPS="sudo wheel admin docker adm lxd incus libvirt aad_admins onbehalf-operators"

privileged_groups_of() {
  local g out=
  for g in $(id -nG "$1"); do
    case " $PRIVILEGED_GROUPS " in *" $g "*) out="$out $g" ;; esac
  done
  echo "${out# }"
}

cmd_user_add() {
  need_root
  load_conf
  local replace=no entra='' names=() u
  while [ $# -gt 0 ]; do
    case $1 in
      --replace-config)
        replace=yes
        shift
        ;;
      --entra-id)
        entra=${2:-}
        entra=${entra,,}
        shift 2
        ;;
      -*) die "unknown option: $1" ;;
      *)
        names+=("$1")
        shift
        ;;
    esac
  done
  [ ${#names[@]} -gt 0 ] || die "usage: onbehalf user add [--replace-config] [--entra-id ID] NAME..."
  if [ -n "$entra" ]; then
    [ ${#names[@]} = 1 ] || die "--entra-id links one user. Give one name"
    entra_valid_id "$entra" || die "not an Entra object id: $entra"
  fi
  [ -e "$ONBEHALF_STACK/current" ] || die "no shared stack yet. Run: sudo onbehalf stack install DIR"

  for u in "${names[@]}"; do user_add_one "$u" "$replace" "$entra"; done

  onboarding_steps
  [ "$UI_ERRORS" = 0 ] || exit 1
}

onboarding_steps() {
  heading "Send each user these steps"
  cat <<EOF
  1. Log in to this host with your own account:   ssh <you>@$(uname -n)
  2. Start the AI harness:                        $(harness command)
  3. Sign in to work tools with your own account when needed.
     For problems, run:                          onbehalf status
  4. Make your own changes without root: settings, agents, skills,
     tools in your home directory and repositories.

  User guide: $ONBEHALF_SHARE/docs/user-guide.md
EOF
}

# Create or adopt one user, give them a personal gateway key and connect
# their harness to the shared stack. With an Entra object id (and UPN), link
# the account to that Entra account. With OWNER, the account is the agent
# account of that operator.
user_add_one() {
  local u=$1 replace=$2 entra=${3:-} upn=${4:-} owner=${5:-} home group key mode groups linked models meta='{}'
  heading "$u"
  # A new account needs a portable name; an existing one may be a UPN.
  if id "$u" >/dev/null 2>&1; then
    user_name_valid "$u" || die "invalid account name: $u"
  else
    account_name_valid "$u" || die "invalid account name: $u"
  fi
  if [ -n "$entra" ]; then
    linked=$(entra_id_of "$u")
    [ -z "$linked" ] || [ "$linked" = "$entra" ] || die "$u is linked to a different Entra account ($linked)"
    linked=$(entra_name_of "$entra")
    [ -z "$linked" ] || [ "$linked" = "$u" ] || die "Entra account $entra is linked to $linked already"
  fi

  if id "$u" >/dev/null 2>&1; then
    [ "$(id -u "$u")" -ge 1000 ] || die "$u is a system account"
    ok "uses the existing account $u"
  else
    useradd -m -s /bin/bash "$u"
    ok "created the account $u"
  fi
  home=$(home_of "$u")
  group=$(id -gn "$u")

  if [ -n "$entra" ]; then
    [ -n "$upn" ] || upn=$(entra_upn_of "$u")
    entra_link "$u" "$entra" "$upn"
    ok "linked to Entra account ${upn:-$entra}"
    meta=$(jq -nc --arg id "$entra" --arg upn "$upn" '{entra_object_id: $id, entra_upn: $upn}')
  elif [ -n "$owner" ]; then
    # Model use of an agent account belongs to its operator.
    meta=$(jq -nc --arg o "$owner" '{agent_of: $o} + (if ($o | contains("@")) then {entra_upn: $o} else {} end)')
  elif [[ $u == *@* ]]; then
    # An account of the Entra login is named by the UPN of the user.
    meta=$(jq -nc --arg upn "$u" '{entra_upn: $upn}')
  fi

  mode=$(stat -c %a "$home")
  if [ "$mode" != 700 ]; then
    chmod 0700 "$home"
    ok "made the home directory private (was $mode, now 700)"
  fi

  install -d -o "$u" -g "$group" -m 0700 "$home/.config" "$home/.config/onbehalf"
  models=$(stack_models "$ONBEHALF_STACK/current") || die "the current stack has no model catalog"
  if [ -s "$home/.config/onbehalf/gateway.key" ]; then
    gateway_models_update "$u" "$models"
    ok "has a personal gateway key"
  else
    key=$(gateway_admin POST /key/generate "$(jq -nc --arg u "$u" --arg a "$u@$(uname -n)" --argjson m "$meta" --argjson models "$models" --argjson routes "$GATEWAY_USER_ROUTES" \
      '{user_id: $u, key_alias: $a, metadata: $m, models: $models, allowed_routes: $routes}')" | jq -r .key)
    [ -n "$key" ] && [ "$key" != null ] || die "the gateway did not return a key for $u"
    printf %s "$key" | install -o "$u" -g "$group" -m 0600 /dev/stdin "$home/.config/onbehalf/gateway.key"
    gateway_models_match "$u" "$models" || die "the gateway did not limit the gateway key of $u to the model catalog"
    removed_clear "$u"
    ok "created a personal gateway key"
  fi

  harness user_add "$u" "$home" "$group" "$replace"

  groups=$(privileged_groups_of "$u")
  if [ -n "$groups" ]; then
    warn "$u is in the group(s) $groups: $u can act as other users"
    fix "gpasswd -d $u <group>   (for each group)"
  fi
}

# onbehalf user remove: offboard a user. The order stops the user first
# (lock, kill), then revokes model access, then removes everything they own.
cmd_user_remove() {
  need_root
  load_conf
  local u=${1:-}
  [ -n "$u" ] || die "usage: onbehalf user remove NAME"
  user_remove_one "$u"

  heading "Also revoke $u outside this host"
  echo "  Entra ID, the GitHub organization, and other cloud accounts."
}

user_remove_one() {
  local u=$1 uid="" home="" local=no
  heading "Remove $u"
  if id "$u" >/dev/null 2>&1; then
    uid=$(id -u "$u")
    home=$(home_of "$u")
    [ "$uid" -ge 1000 ] || die "onbehalf does not remove the system account $u"

    if local_account "$u"; then
      local=yes
      usermod -L -e 1 "$u"
    fi
    user_stop "$u" "$uid"
    if is_operator "$u"; then gpasswd -d "$u" "$OPERATOR_GROUP" >/dev/null; fi
    if [ "$local" = yes ]; then
      ok "locked the account and stopped all processes"
    else
      ok "stopped all processes ($u is a directory account; onbehalf cannot lock it)"
    fi
  else
    info "no account $u on this host. onbehalf revokes only the gateway access"
  fi

  gateway_revoke_all "$u"
  removed_mark "$u"
  rm -f "$ENROLL_STATE/$u"
  harness user_remove "$u"
  agents_unlink "$u"

  if [ -n "$uid" ]; then
    # Best effort: these may be absent or fail (no cron, no running systemd).
    if command -v crontab >/dev/null; then crontab -r -u "$u" 2>/dev/null || true; fi
    if command -v loginctl >/dev/null; then loginctl disable-linger "$u" 2>/dev/null || true; fi
    find /tmp /var/tmp /dev/shm -xdev -uid "$uid" -delete 2>/dev/null || true
    if [ "$local" = yes ]; then
      userdel -r "$u" 2>/dev/null || [ ! -e "$home" ] || die "could not remove account $u"
      ok "removed the account, $home and its credentials"
    else
      # The directory keeps the account. Its home and credentials go, but
      # only a home of its own: never /, a shared or a missing directory.
      if [ -d "$home" ] && [ "$home" != / ] && [ "$(stat -c %u "$home")" = "$uid" ]; then
        rm -rf --one-file-system "$home" || die "could not remove $home"
        ok "removed $home and its credentials"
      fi
      warn "$u can still log in through the directory, and onbehalf enrolls $u again at the next login"
      fix "remove the login permission of $u first (Azure: the role Virtual Machine User Login)"
    fi

    local left
    left=$(find / -xdev -uid "$uid" 2>/dev/null | head -5)
    if [ -n "$left" ]; then
      warn "files of uid $uid are still on the host:"$'\n'"$(sed 's/^/        /' <<<"$left")"
      fix "remove them before a new account gets uid $uid"
    fi
  fi

  if [ -n "$(entra_id_of "$u")" ]; then
    entra_unlink "$u"
    ok "removed the link to Entra"
  fi
}

# user_stop NAME UID: stop every process of a user.
user_stop() {
  for _ in $(seq 20); do
    pkill -KILL -u "$2" 2>/dev/null || break
    sleep 0.5
  done
  ! pgrep -u "$2" >/dev/null || die "processes of $1 still run"
}

# Revoke every gateway key of a user. Spend logs stay for the audit trail.
# A failed lookup must stop the removal: "no keys found" is not "no keys".
gateway_revoke_all() {
  local u=$1 q keys
  q=$(jq -rn --arg u "$u" '$u | @uri')
  keys=$(gateway_admin GET "/key/list?user_id=$q&return_full_object=true&size=100" | jq -ec '[.keys[].token]') \
    || die "could not list the gateway keys of $u. onbehalf revoked nothing"
  if [ "$keys" != '[]' ]; then
    gateway_admin POST /key/delete "{\"keys\":$keys}" >/dev/null || die "could not revoke gateway keys of $u"
  fi
  [ "$(gateway_admin GET "/key/list?user_id=$q" | jq '.keys | length')" = 0 ] \
    || die "gateway keys of $u are still active"
  ok "revoked all gateway keys (the gateway keeps the model use records)"
}
