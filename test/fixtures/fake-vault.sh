#!/usr/bin/env bash
# Stand-in for a work tool of the shared stack in tests (tools/vault.json):
# vault token lookup, vault login and vault print token. The login asks which
# account to log in as; "cancel" fails like a cancelled login.
# State: ~/.fake-vault-user, the account this user is "logged in" as.
set -euo pipefail
case "${1:-} ${2:-}" in
  "token lookup") [ -r ~/.fake-vault-user ] ;;
  "print token") cat ~/.fake-vault-user ;;
  "login "*)
    read -r -p "fake vault: account to log in as: " a </dev/tty || exit 1
    [ "$a" != cancel ] || exit 1
    echo "$a" >~/.fake-vault-user
    ;;
  *)
    echo "fake vault: not supported: $*" >&2
    exit 2
    ;;
esac
