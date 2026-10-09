# Login shells only. Do not prompt during SSH commands or file transfers.
case $- in
  *i*)
    if [ -t 0 ] && [ -t 1 ] && command -v onbehalf >/dev/null 2>&1; then
      onbehalf login || :
    fi
    # Operators run no agent in their own account: an agent there could use
    # sudo. Point them to the agent account. This guides; it does not enforce.
    if id -Gn 2>/dev/null | tr ' ' '\n' | grep -qx onbehalf-operators; then
      opencode() {
        case "${1:-} ${2:-}" in
          "--version "* | "-v "* | "--help "* | "-h "* | "service stop" | "service status")
            command opencode "$@"
            return
            ;;
        esac
        echo "onbehalf: operators run no runtime in this account, because a runtime here can use sudo." >&2
        echo "  open your runtime account: sudo onbehalf operator shell" >&2
        return 1
      }
    fi
    ;;
esac
