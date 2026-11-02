# shellcheck shell=bash
# onbehalf route: the route of an interface broker to the runtime of one
# user. The broker maps a login to a Unix account, then calls this command.
# See docs/design/session-board.md.
#
#   sudo onbehalf route NAME          JSON: user, url, username, password
#   sudo onbehalf route --upn UPN     the same, for the user linked to UPN

cmd_route() {
  need_root
  local usage="usage: sudo onbehalf route NAME | --upn UPN" u
  case "$#:${1:-}" in
    1:-*) die "$usage" ;;
    1:*) u=$1 ;;
    2:--upn)
      # Only the Entra map gives the account of a login. A login that is
      # not in the map gets no route, also if it is an account name.
      [[ $2 == ?*@?* ]] || die "not a UPN: $2"
      u=$(entra_name_of_upn "$2")
      [ -n "$u" ] && [ "$(wc -l <<<"$u")" -eq 1 ] || die "no user on this host is linked to $2"
      ;;
    *) die "$usage" ;;
  esac
  load_conf
  people | grep -qxF -- "$u" || die "$u is not a user on this host"
  harness route "$u"
}
