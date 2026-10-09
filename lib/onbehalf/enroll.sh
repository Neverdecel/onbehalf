# shellcheck shell=bash
# Auto-enroll: every user who can log in to this host joins onbehalf at their
# first login. The login permission is the only access decision; on Azure VMs
# that is the Entra login with the role Virtual Machine User Login.
#
# sshd runs `onbehalf user enroll --pam` as root through pam_exec when a
# session opens. It never blocks a login: a failure goes to the log, and the
# login message of the user says so. Administrators never join.
#
# Users who joined this way and did not log in for ONBEHALF_ENROLL_IDLE_DAYS
# lose their gateway key (`onbehalf user prune`, daily timer). Their files
# stay; the next login gives a new key.

ENROLL_CONF=${ENROLL_CONF:-$ONBEHALF_ETC/enroll.conf}
ENROLL_PAM_FILE=${ENROLL_PAM_FILE:-/etc/pam.d/sshd}
ENROLL_LOG=${ENROLL_LOG:-/var/log/onbehalf-enroll.log}
ENROLL_LOCK=${ENROLL_LOCK:-/run/onbehalf-enroll.lock}
ENROLL_UNITS=${ENROLL_UNITS:-/etc/systemd/system}
ENROLL_MARK="# onbehalf auto-enroll"

# Read enroll.conf into ONBEHALF_AUTO_ENROLL, _IDLE_DAYS and _EXCLUDE.
enroll_conf() {
  ONBEHALF_AUTO_ENROLL=no ONBEHALF_ENROLL_IDLE_DAYS=30 ONBEHALF_ENROLL_EXCLUDE=
  # shellcheck source=/dev/null
  [ ! -r "$ENROLL_CONF" ] || . "$ENROLL_CONF"
}

enroll_save() {
  cat >"$ENROLL_CONF" <<EOF
# onbehalf auto-enroll. Change it with: sudo onbehalf auto-enroll on|off
ONBEHALF_AUTO_ENROLL=$1
ONBEHALF_ENROLL_IDLE_DAYS=$ONBEHALF_ENROLL_IDLE_DAYS
ONBEHALF_ENROLL_EXCLUDE=$(printf %q "$ONBEHALF_ENROLL_EXCLUDE")
EOF
  chmod 0644 "$ENROLL_CONF"
}

enroll_pam_installed() { grep -qF -- "$ENROLL_MARK" "$ENROLL_PAM_FILE" 2>/dev/null; }

# Remove our lines from the PAM file, if there are any.
enroll_pam_remove() {
  enroll_pam_installed || return 0
  local tmp
  tmp=$(mktemp "$ENROLL_PAM_FILE.XXXXXX")
  grep -vF -e "$ENROLL_MARK" -e ' user enroll --pam' "$ENROLL_PAM_FILE" >"$tmp" || true
  chmod --reference="$ENROLL_PAM_FILE" "$tmp"
  mv "$tmp" "$ENROLL_PAM_FILE"
}

# onbehalf auto-enroll on|off|status
cmd_auto_enroll() {
  need_root
  load_conf
  local action=${1:-status} days='' exclude='' set_exclude=no
  [ $# = 0 ] || shift
  while [ $# -gt 0 ]; do
    case $1 in
      --idle-days)
        days=${2:-}
        [[ $days =~ ^[1-9][0-9]{0,3}$ ]] || die "give --idle-days a number of days"
        shift 2
        ;;
      --exclude)
        exclude=${2:-}
        set_exclude=yes
        shift 2
        ;;
      *) die "unknown option: $1" ;;
    esac
  done
  enroll_conf
  [ -z "$days" ] || ONBEHALF_ENROLL_IDLE_DAYS=$days
  [ "$set_exclude" = no ] || ONBEHALF_ENROLL_EXCLUDE=$exclude
  case $action in
    on) enroll_enable ;;
    off) enroll_disable ;;
    status)
      heading "Auto-enroll"
      enroll_check
      [ "$UI_ERRORS" = 0 ] || exit 1
      ;;
    *) die "usage: onbehalf auto-enroll on|off|status [--idle-days N] [--exclude 'NAME...']" ;;
  esac
}

enroll_enable() {
  local bin timeout_bin
  heading "Auto-enroll: enroll users at their first login"
  [ -e "$ONBEHALF_STACK/current" ] || die "no shared stack yet. Run: sudo onbehalf stack install DIR"
  [ -f "$ENROLL_PAM_FILE" ] || die "$ENROLL_PAM_FILE is not on the host. Install the OpenSSH server first"
  bin=$(readlink -f "$0")
  timeout_bin=$(command -v timeout) || die "timeout is not installed (coreutils)"

  enroll_save yes
  install -d -m 0700 "$ENROLL_STATE"
  ok "saved $ENROLL_CONF"

  # Last in the file: after the session modules that make the home directory.
  enroll_pam_remove
  printf '%s: enroll in onbehalf at the first login. Never stops a login\nsession optional pam_exec.so quiet %s 90 %s user enroll --pam\n' \
    "$ENROLL_MARK" "$timeout_bin" "$bin" >>"$ENROLL_PAM_FILE"
  ok "sshd runs the enrollment when a session opens ($ENROLL_PAM_FILE)"

  enroll_timer_install "$bin"
  info "onbehalf does not enroll administrators: root, system accounts, members of $PRIVILEGED_GROUPS,"
  info "and accounts that can use sudo.${ONBEHALF_ENROLL_EXCLUDE:+ Also excluded: $ONBEHALF_ENROLL_EXCLUDE.}"
  info "Users who do not log in for $ONBEHALF_ENROLL_IDLE_DAYS days lose their gateway key. Their files stay."
  info "Log of each enrollment: $ENROLL_LOG and journalctl -t onbehalf"
}

enroll_disable() {
  heading "Auto-enroll: off"
  enroll_save no
  enroll_pam_remove
  ok "sshd no longer runs the enrollment"
  rm -f "$ENROLL_UNITS/onbehalf-prune.service" "$ENROLL_UNITS/onbehalf-prune.timer"
  if [ -d /run/systemd/system ]; then
    systemctl disable --now onbehalf-prune.timer >/dev/null 2>&1 || true
    systemctl daemon-reload
  fi
  ok "removed the daily prune timer"
  info "The enrolled users stay. To remove one: sudo onbehalf user remove NAME"
}

enroll_timer_install() {
  cat >"$ENROLL_UNITS/onbehalf-prune.service" <<EOF
[Unit]
Description=onbehalf: revoke the gateway keys of users who stopped logging in

[Service]
Type=oneshot
ExecStart=$1 user prune
EOF
  cat >"$ENROLL_UNITS/onbehalf-prune.timer" <<EOF
[Unit]
Description=onbehalf: daily prune of users who stopped logging in

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  chmod 0644 "$ENROLL_UNITS"/onbehalf-prune.*
  if [ -d /run/systemd/system ]; then
    systemctl daemon-reload && systemctl enable --now onbehalf-prune.timer >/dev/null 2>&1 \
      || die "could not start onbehalf-prune.timer"
    ok "a daily timer runs: onbehalf user prune"
  else
    warn "systemd does not run here, so the daily prune does not run"
    fix "run 'sudo onbehalf user prune' one time each day, for example from cron"
  fi
}

# Checks for doctor and auto-enroll status.
enroll_check() {
  enroll_conf
  if [ "$ONBEHALF_AUTO_ENROLL" != yes ]; then
    if enroll_pam_installed; then
      warn "auto-enroll is off, but $ENROLL_PAM_FILE still runs it"
      fix "sudo onbehalf auto-enroll off"
    else
      info "auto-enroll is off: an operator adds each user"
    fi
    return 0
  fi
  ok "auto-enroll is on: onbehalf enrolls users at their first login"
  if enroll_pam_installed; then
    ok "sshd runs the enrollment ($ENROLL_PAM_FILE)"
  else
    err "$ENROLL_PAM_FILE does not run the enrollment, so onbehalf enrolls nobody"
    fix "sudo onbehalf auto-enroll on"
  fi
  if [ ! -d /run/systemd/system ]; then
    info "no systemd: run 'sudo onbehalf user prune' one time each day"
  elif systemctl is-enabled onbehalf-prune.timer >/dev/null 2>&1; then
    ok "users who do not log in for $ONBEHALF_ENROLL_IDLE_DAYS days lose their gateway key (daily timer)"
  else
    warn "the daily prune timer is not enabled"
    fix "sudo onbehalf auto-enroll on"
  fi
  [ -z "$ONBEHALF_ENROLL_EXCLUDE" ] || info "excluded: $ONBEHALF_ENROLL_EXCLUDE"
}

# Why an account must not join; prints nothing and fails if it may join.
enroll_refusal() {
  local u=$1 uid groups
  if ! user_name_valid "$u"; then
    echo "onbehalf does not support this account name"
  elif ! uid=$(id -u "$u" 2>/dev/null); then
    echo "there is no such account"
  elif [ "$uid" -lt 1000 ]; then
    echo "it is a system account"
  elif [[ " $ONBEHALF_ENROLL_EXCLUDE " == *" $u "* ]]; then
    echo "it is excluded in $ENROLL_CONF"
  elif groups=$(privileged_groups_of "$u") && [ -n "$groups" ]; then
    echo "it is an administrator (group $groups)"
  elif can_sudo "$u"; then
    echo "it is an administrator (it can use sudo)"
  else
    return 1
  fi
}

# True if sudo gives the account any rule. Fails closed: a sudo error counts.
can_sudo() {
  command -v sudo >/dev/null || return 1
  ! LC_ALL=C sudo -n -l -U "$1" 2>&1 | grep -q "is not allowed to run sudo"
}

# onbehalf user enroll NAME     (operator: enroll one account now)
# onbehalf user enroll --pam    (sshd, through pam_exec)
cmd_user_enroll() {
  need_root
  if [ "${1:-}" = --pam ]; then
    # pam_exec gives an almost empty environment.
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    enroll_pam
    return 0
  fi
  [ $# = 1 ] || die "usage: onbehalf user enroll NAME"
  load_conf
  enroll_one "$1"
}

enroll_one() {
  local u=$1 why had_key=no home
  enroll_conf
  why=$(enroll_refusal "$u") && die "onbehalf does not enroll $u: $why"
  [ -e "$ONBEHALF_STACK/current" ] || die "no shared stack yet. Run: sudo onbehalf stack install DIR"
  home=$(home_of "$u" || true)
  [ ! -s "$home/.config/onbehalf/gateway.key" ] || had_key=yes
  install -d -m 0700 "$ENROLL_STATE"
  # One at a time: parallel first logins must not share a service port.
  exec 9>"$ENROLL_LOCK"
  flock -w 60 9 || die "a different enrollment did not finish in 60 seconds"
  user_add_one "$u" no
  # Only users who joined this way can be pruned, not those an operator added.
  [ "$had_key" = yes ] || touch "$ENROLL_STATE/$u"
  [ "$UI_ERRORS" = 0 ]
}

# Called by pam_exec for every SSH session. Never fails.
enroll_pam() {
  [ "${PAM_TYPE:-}" = open_session ] || return 0
  local u=${PAM_USER:-} home out rc=0
  [ -r "$ONBEHALF_ETC/onbehalf.conf" ] && user_name_valid "$u" || return 0
  enroll_conf
  [ "$ONBEHALF_AUTO_ENROLL" = yes ] || return 0

  # Fast path, on every login of a user: record the login.
  home=$(home_of "$u" || true)
  if [ -n "$home" ] && [ -s "$home/.config/onbehalf/gateway.key" ]; then
    [ ! -e "$ENROLL_STATE/$u" ] || touch "$ENROLL_STATE/$u"
    return 0
  fi
  enroll_refusal "$u" >/dev/null && return 0

  out=$( (
    load_conf
    enroll_one "$u"
  ) 2>&1) || rc=$?
  enroll_log "$u" "$rc" "$out"
  return 0
}

enroll_log() {
  local u=$1 rc=$2 out=$3 result
  [ "$rc" = 0 ] && result="enrolled in onbehalf" || result="could not enroll in onbehalf (exit $rc)"
  (
    umask 077
    {
      printf '%s %s %s\n' "$(date -Is)" "$u" "$result"
      sed 's/^/    /' <<<"$out"
    } >>"$ENROLL_LOG"
  ) 2>/dev/null || true
  logger -t onbehalf -p "authpriv.$([ "$rc" = 0 ] && echo info || echo err)" "$u $result: $(tr '\n' ' ' <<<"$out" | tr -s ' ')" \
    2>/dev/null || true
}

# onbehalf user prune [--dry-run]: revoke the gateway key of users who
# joined at login and did not log in for ONBEHALF_ENROLL_IDLE_DAYS days.
# Their files stay. A user with running processes counts as active.
cmd_user_prune() {
  need_root
  load_conf
  enroll_conf
  local dry=no u uid home n=0
  case ${1:-} in
    "") ;;
    --dry-run) dry=yes ;;
    *) die "usage: onbehalf user prune [--dry-run]" ;;
  esac
  heading "Users who did not log in for $ONBEHALF_ENROLL_IDLE_DAYS days"
  for u in $(enrolled_names); do
    [ -n "$(find "$ENROLL_STATE/$u" -mmin +$((ONBEHALF_ENROLL_IDLE_DAYS * 1440)))" ] || continue
    uid=$(id -u "$u" 2>/dev/null) || uid=
    if [ -n "$uid" ] && pgrep -u "$uid" >/dev/null; then
      [ "$dry" = yes ] || touch "$ENROLL_STATE/$u"
      info "$u has processes that run, so $u is active"
      continue
    fi
    n=$((n + 1))
    if [ "$dry" = yes ]; then
      info "would revoke the gateway key of $u"
      continue
    fi
    gateway_revoke_all "$u"
    removed_mark "$u"
    home=$(home_of "$u" || true)
    [ -z "$home" ] || rm -f "$home/.config/onbehalf/gateway.key"
    rm -f "$ENROLL_STATE/$u"
    # An account that is gone keeps no port; a returning one keeps its port.
    [ -n "$uid" ] || harness_opencode_port_release "$u"
    ok "$u: the files stay. The next login gives a new key"
  done
  [ "$n" -gt 0 ] || ok "none"
}
