#!/usr/bin/env bash
# Stand-in for the Azure CLI in the demo: az login --use-device-code,
# az account show and az logout. The login looks like the device login of the
# real CLI and logs in as <account>@example.com. State: ~/.demo-az-user.
set -euo pipefail
case "${1:-} ${2:-}" in
  "account show")
    [ -r ~/.demo-az-user ] || {
      echo "Please run 'az login' to setup account." >&2
      exit 1
    }
    user=$(cat ~/.demo-az-user)
    if [ "${3:-}" = --query ]; then
      echo "$user"
    else
      jq -n --arg u "$user" '{name: "Example subscription", tenantDisplayName: "Example", user: {name: $u}}'
    fi
    ;;
  "login --use-device-code")
    echo "To sign in, use a web browser to open the page https://microsoft.com/devicelogin and enter the code DXQ7-4HTM to authenticate."
    read -r -p "Press Enter after you sign in " _ </dev/tty
    sleep 1
    echo "$(id -un)@example.com" >~/.demo-az-user
    ;;
  "logout "*) rm -f ~/.demo-az-user ;;
  *)
    echo "az (demo): not supported: $*" >&2
    exit 2
    ;;
esac
