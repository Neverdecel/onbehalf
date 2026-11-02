# shellcheck shell=bash
# onbehalf route: the route of an interface broker to the runtime of one
# user. The broker maps a login to a Unix account, then calls this command.
# See docs/design/session-board.md.
#
#   sudo onbehalf route NAME    JSON: user, url, username, password

cmd_route() {
  need_root
  [ $# -eq 1 ] && [ "${1#-}" = "$1" ] || die "usage: sudo onbehalf route NAME"
  load_conf
  local u=$1
  people | grep -qxF -- "$u" || die "$u is not a user on this host"
  harness route "$u"
}
