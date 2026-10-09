#!/usr/bin/env bash
# Stand-in for the GitHub CLI in tests: gh auth status and gh auth login.
# The login asks which account to log in as; "cancel" fails like a cancelled
# login. State: ~/.fake-gh-user, the account this user is "logged in" as.
set -euo pipefail
case "${1:-} ${2:-}" in
  "auth status")
    if [ ! -r ~/.fake-gh-user ]; then
      echo "You are not logged into any GitHub hosts. To log in, run: gh auth login" >&2
      exit 1
    fi
    printf 'github.com\n  ✓ Logged in to github.com account %s (keyring)\n' "$(cat ~/.fake-gh-user)"
    ;;
  "auth login")
    echo "! First copy your one-time code: 7F3A-9C21"
    read -r -p "fake gh: account to log in as: " a </dev/tty || exit 1
    [ "$a" != cancel ] || exit 1
    echo "$a" >~/.fake-gh-user
    echo "✓ Logged in as $a"
    ;;
  *)
    echo "fake gh: not supported: $*" >&2
    exit 2
    ;;
esac
