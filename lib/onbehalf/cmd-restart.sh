# shellcheck shell=bash
# onbehalf restart: restart an OpenCode service, so that it reads a changed
# configuration or a new OpenCode version. A restart stops the agent work
# that runs at that time.
#
#   onbehalf restart              a user: their own service
#   sudo onbehalf restart         an operator: the service of their agent account
#   sudo onbehalf restart NAME    the service of the user NAME
#   sudo onbehalf restart --all   every running service

cmd_restart() {
  local all=no u=''
  while [ $# -gt 0 ]; do
    case $1 in
      --all)
        all=yes
        shift
        ;;
      -*) die "unknown option: $1" ;;
      *)
        [ -z "$u" ] || die "usage: onbehalf restart [NAME | --all]"
        u=$1
        shift
        ;;
    esac
  done
  [ "$all" = no ] || [ -z "$u" ] || die "usage: onbehalf restart [NAME | --all]"

  # A user restarts their own service, without root.
  if [ "$(id -u)" != 0 ]; then
    if [ "$all" = yes ] || { [ -n "$u" ] && [ "$u" != "$(id -un)" ]; }; then
      die "a user restarts only their own runtime. For other users: sudo onbehalf restart NAME"
    fi
    load_conf
    restart_self
    return
  fi

  load_conf
  if [ "$all" = yes ]; then
    heading "Restart all runtimes"
    local n=0
    for u in $(people); do
      if pgrep -u "$u" -f 'serve --service' >/dev/null; then
        restart_one "$u"
        n=$((n + 1))
      fi
    done
    [ "$n" -gt 0 ] || info "no runtime runs"
    [ "$UI_ERRORS" = 0 ] || exit 1
    return
  fi

  if [ -z "$u" ]; then
    local caller=${SUDO_USER:-root}
    [ "$caller" != root ] || die "usage: onbehalf restart NAME | --all"
    u=$(agent_of "$caller")
    [ -n "$u" ] || die "$caller has no runtime account. To make it: sudo onbehalf operator add --runtime $caller"
  fi
  people | grep -qxF -- "$u" || die "$u is not a user on this host"
  heading "Restart the runtime of $u"
  restart_one "$u"
  [ "$UI_ERRORS" = 0 ] || exit 1
}

restart_self() {
  local u
  u=$(id -un)
  ! is_operator "$u" || die "operators run no runtime in this account. For your runtime account: sudo onbehalf restart"
  [ -e "$HOME/.config/onbehalf/gateway.key" ] || die "you are not a user on this host. Ask your operator to run: sudo onbehalf user add $u"
  heading "Restart your runtime"
  opencode service restart >/dev/null || die "the runtime did not restart. Check: onbehalf status"
  ok "restarted your runtime"
}

restart_one() {
  as_user "$1" "opencode service restart" >/dev/null || {
    err "the runtime of $1 did not restart"
    return 0
  }
  ok "restarted the runtime of $1"
}
