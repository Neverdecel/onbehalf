#!/usr/bin/env bash
# Stand-in for the GitHub CLI in the demo: gh auth status and gh auth login.
# The login looks like the device login of the real CLI and logs in as the
# account name. State: ~/.demo-gh-user.
set -euo pipefail
case "${1:-} ${2:-}" in
  "auth status")
    if [ ! -r ~/.demo-gh-user ]; then
      echo "You are not logged into any GitHub hosts. To log in, run: gh auth login" >&2
      exit 1
    fi
    printf 'github.com\n  ✓ Logged in to github.com account %s (keyring)\n' "$(cat ~/.demo-gh-user)"
    ;;
  "auth login")
    echo "! First copy your one-time code: 7F3A-9C21"
    read -r -p "Open https://github.com/login/device in your browser, then press Enter " _ </dev/tty
    sleep 1
    echo "✓ Authentication complete."
    echo "✓ Logged in as $(id -un)"
    id -un >~/.demo-gh-user
    ;;
  *)
    echo "gh (demo): not supported: $*" >&2
    exit 2
    ;;
esac
