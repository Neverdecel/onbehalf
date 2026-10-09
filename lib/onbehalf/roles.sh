# shellcheck shell=bash
# Roles: each account is an operator or a user, never both.
#
# Operators run onbehalf as root (sudo, for this command only) and decide the
# shared setup for everyone. Users run agents. An agent that could use
# sudo could act as every other user, so an operator account never gets a
# gateway key. An operator who also wants an agent gets an agent account: a
# separate local user without sudo, opened with `onbehalf operator shell`.

OPERATOR_GROUP=onbehalf-operators
OPERATOR_SUDOERS=${OPERATOR_SUDOERS:-/etc/sudoers.d/onbehalf-operators}
AGENTS_MAP=${AGENTS_MAP:-$ONBEHALF_ETC/agents} # lines: AGENT OPERATOR

operators() { getent group "$OPERATOR_GROUP" | cut -d: -f4 | tr ',' '\n' | grep . || true; }
is_operator() { operators | grep -qxF -- "$1"; }

agent_of() { [ -r "$AGENTS_MAP" ] && awk -v o="$1" '$2 == o { print $1 }' "$AGENTS_MAP" || true; }
owner_of() { [ -r "$AGENTS_MAP" ] && awk -v a="$1" '$1 == a { print $2 }' "$AGENTS_MAP" || true; }

agents_link() {
  local tmp
  tmp=$(mktemp "$AGENTS_MAP.XXXXXX")
  {
    [ -r "$AGENTS_MAP" ] && awk -v a="$1" '$1 != a' "$AGENTS_MAP"
    printf '%s %s\n' "$1" "$2"
  } | sort >"$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$AGENTS_MAP"
}

# Forget NAME as an agent account.
agents_unlink() {
  [ -n "$(owner_of "$1")" ] || return 0
  local tmp
  tmp=$(mktemp "$AGENTS_MAP.XXXXXX")
  awk -v a="$1" '$1 != a' "$AGENTS_MAP" >"$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$AGENTS_MAP"
}

# Agent account name for an operator: alice.smith@corp.com becomes
# alice-smith-agent. Local, so it needs a portable name.
agent_name_for() {
  local LC_ALL=C n=${1%@*}
  n=${n,,}
  n=${n//./-}
  n="${n:0:25}-agent"
  account_name_valid "$n" && echo "$n" || true
}

# onbehalf operator add|remove|list|shell
cmd_operator() {
  local action=${1:-list}
  [ $# = 0 ] || shift
  case $action in
    add) operator_add "$@" ;;
    remove) operator_remove "$@" ;;
    list) operator_list ;;
    shell) operator_shell "$@" ;;
    *) die "usage: onbehalf operator add [--runtime] NAME | remove NAME | list | shell [-c COMMAND]" ;;
  esac
}

# The sudo rule: members may run onbehalf as root, and nothing else. sudo
# resets the environment, so a caller cannot redirect onbehalf to other code.
operator_sudoers_install() {
  local bin tmp
  command -v visudo >/dev/null || die "sudo is not installed. Operators must have sudo"
  bin=$(readlink -f "$0")
  tmp=$(mktemp)
  cat >"$tmp" <<EOF
# onbehalf operators may run onbehalf as root, and nothing else.
# Managed by: onbehalf operator add|remove
Defaults!$bin env_reset
%$OPERATOR_GROUP ALL=(root) NOPASSWD: $bin
EOF
  visudo -cqf "$tmp" || {
    rm -f "$tmp"
    die "the sudo rule for operators is not valid"
  }
  install -m 0440 -o root -g root "$tmp" "$OPERATOR_SUDOERS"
  rm -f "$tmp"
}

operator_add() {
  need_root
  load_conf
  local u='' agent=no uid home groups a
  while [ $# -gt 0 ]; do
    case $1 in
      --runtime | --agent)
        agent=yes
        shift
        ;;
      -*) die "unknown option: $1" ;;
      *)
        u=$1
        shift
        ;;
    esac
  done
  [ -n "$u" ] || die "usage: onbehalf operator add [--runtime] NAME"
  heading "Operator $u"
  user_name_valid "$u" || die "invalid account name: $u"
  uid=$(id -u "$u" 2>/dev/null) || die "there is no account $u; the user logs in once first"
  [ "$uid" -ge 1000 ] || die "$u is a system account"
  [ -z "$(owner_of "$u")" ] || die "$u is the runtime account of $(owner_of "$u"). A runtime account cannot be an operator"

  # An operator runs no agent: revoke the user setup first.
  home=$(home_of "$u" || true)
  if [ -n "$home" ] && [ -e "$home/.config/onbehalf/gateway.key" ]; then
    gateway_revoke_all "$u"
    removed_mark "$u"
    rm -f "$home/.config/onbehalf/gateway.key" "$ENROLL_STATE/$u"
    harness stop "$u"
    ok "$u is not a user now: the gateway key is revoked, the runtime of $u is stopped, the files stay"
  fi

  getent group "$OPERATOR_GROUP" >/dev/null || groupadd -r "$OPERATOR_GROUP"
  operator_sudoers_install
  if is_operator "$u"; then
    ok "$u is an operator"
  else
    gpasswd -a "$u" "$OPERATOR_GROUP" >/dev/null
    ok "$u is an operator: may run 'sudo onbehalf', and no other sudo command"
  fi
  groups=$(privileged_groups_of "$u")
  groups=${groups//$OPERATOR_GROUP/}
  groups=${groups% }
  if [ -n "${groups// /}" ]; then
    warn "$u also has full root through the group(s) $groups"
    fix "keep full root for a break-glass account; on Azure, give $u the role Virtual Machine User Login"
  fi

  [ "$agent" = yes ] || {
    [ -n "$(agent_of "$u")" ] || info "to get a runtime too: sudo onbehalf operator add --runtime $u"
    return 0
  }
  a=$(agent_of "$u")
  if [ -z "$a" ]; then
    a=$(agent_name_for "$u")
    [ -n "$a" ] || die "onbehalf cannot make a runtime account name from $u"
    [ -z "$(owner_of "$a")" ] || die "the account $a is the runtime account of $(owner_of "$a")"
    ! id "$a" >/dev/null 2>&1 || die "the account $a is already on the host, so it cannot be the runtime account of $u"
    agents_link "$a" "$u"
  fi
  user_add_one "$a" no '' '' "$u"
  ok "$a is the runtime account of $u, without sudo"
  info "$u opens it with: sudo onbehalf operator shell"
}

operator_remove() {
  need_root
  local u=${1:-} a
  [ -n "$u" ] || die "usage: onbehalf operator remove NAME"
  heading "Operator $u"
  if is_operator "$u"; then
    gpasswd -d "$u" "$OPERATOR_GROUP" >/dev/null
    ok "$u is no longer an operator"
  else
    ok "$u is not an operator"
  fi
  [ -n "$(operators)" ] || warn "there are no operators left; only root can run onbehalf"
  a=$(agent_of "$u")
  if [ -n "$a" ]; then
    warn "the runtime account $a of $u stays, with its files and credentials"
    fix "sudo onbehalf user remove $a"
  fi
  info "$u can now become a user: at the next login (auto-enroll), or with: sudo onbehalf user add $u"
}

operator_list() {
  local u a n=0
  heading "Operators"
  for u in $(operators); do
    n=$((n + 1))
    a=$(agent_of "$u")
    info "$u${a:+ (runtime account: $a)}"
  done
  [ "$n" -gt 0 ] || info "none: only root can run onbehalf"
}

# Open the agent account of the calling operator. Root may name an operator.
operator_shell() {
  need_root
  local caller=${SUDO_USER:-root} owner='' cmd='' a
  while [ $# -gt 0 ]; do
    case $1 in
      -c)
        cmd=${2:-}
        [ -n "$cmd" ] || die "give a command for -c"
        shift 2
        ;;
      -*) die "unknown option: $1" ;;
      *)
        owner=$1
        shift
        ;;
    esac
  done
  if [ "$caller" != root ]; then
    [ -z "$owner" ] || [ "$owner" = "$caller" ] || die "you can open only your own runtime account"
    owner=$caller
  fi
  [ -n "$owner" ] || die "usage: onbehalf operator shell [OPERATOR] [-c COMMAND]"
  a=$(agent_of "$owner")
  [ -n "$a" ] || die "$owner has no runtime account. To make it: sudo onbehalf operator add --runtime $owner"
  if [ -n "$cmd" ]; then
    exec runuser -l "$a" -c "$cmd"
  fi
  exec runuser -l "$a"
}

# Checks for doctor.
operator_check() {
  local ops a o
  ops=$(operators | tr '\n' ' ')
  if [ -n "$ops" ]; then
    ok "operators (may run 'sudo onbehalf'): $ops"
    if [ "$(stat -c '%a %U' "$OPERATOR_SUDOERS" 2>/dev/null || true)" != "440 root" ]; then
      err "the sudo rule for operators is missing or has the wrong mode ($OPERATOR_SUDOERS)"
      fix "sudo onbehalf operator add <an operator>"
    fi
  else
    info "no operators: only root runs onbehalf. Add one: sudo onbehalf operator add NAME"
  fi
  for o in $(operators); do
    if harness operator_runs "$o"; then
      warn "$(harness label) runs in the operator account $o: a runtime there can run 'sudo onbehalf', and it goes around the gateway key"
      fix "as $o: $(harness operator_stop). Then use the runtime account: sudo onbehalf operator shell"
    fi
  done
  [ -r "$AGENTS_MAP" ] || return 0
  if [ "$(stat -c '%a %U' "$AGENTS_MAP")" != "644 root" ]; then
    err "the runtime account links in $AGENTS_MAP have the wrong owner or mode"
    fix "chown root: $AGENTS_MAP && chmod 644 $AGENTS_MAP"
  fi
  while read -r a o; do
    [ -n "$a" ] || continue
    if ! is_operator "$o"; then
      warn "the runtime account $a is the runtime account of $o, who is not an operator"
      fix "sudo onbehalf user remove $a, or: sudo onbehalf operator add $o"
    fi
  done <"$AGENTS_MAP"
}
