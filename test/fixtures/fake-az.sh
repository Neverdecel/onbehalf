#!/usr/bin/env bash
# Stand-in for the Azure CLI in tests. Just enough for onbehalf: find a group
# (az ad group show), read its members from Graph two per page (az rest), show
# who is logged in (az account show), and log in and out. The device-code
# login asks which account to log in as; "cancel" fails like a cancelled login.
#
# State: /tmp/fake-entra/groups.json  {"name": "object id"}
#        /tmp/fake-entra/members.json [Graph user objects]
#        /tmp/fake-entra/fail         if present, every call fails
#        ~/.fake-az-user              the UPN this user is "logged in" as
# Every call is logged as "<caller> <arguments>" in /tmp/fake-entra/calls.log.
set -euo pipefail
dir=/tmp/fake-entra
echo "$(id -un) $*" >>"$dir/calls.log"
if [ -e "$dir/fail" ]; then
  echo "ERROR: AADSTS700082: The refresh token has expired. Run 'az login'." >&2
  exit 1
fi

case "${1:-} ${2:-}" in
  "ad group") # az ad group show --group NAME --query id -o tsv
    jq -er --arg g "$5" '.[$g] // empty' "$dir/groups.json" \
      || {
        echo "ERROR: Resource '$5' does not exist." >&2
        exit 3
      }
    ;;
  "rest --method") # az rest --method get --url URL
    url=$5
    gid=${url#*/groups/}
    gid=${gid%%/*}
    jq -e --arg id "$gid" 'any(.[]; . == $id)' "$dir/groups.json" >/dev/null \
      || {
        echo "ERROR: Not Found: group $gid" >&2
        exit 3
      }
    skip=0
    if [[ $url =~ skiptoken=([0-9]+) ]]; then skip=${BASH_REMATCH[1]}; fi
    echo "WARNING: this fake az talks to no cloud" >&2
    jq --argjson s "$skip" --arg base "${url%%&\$skiptoken=*}" \
      '{value: .[$s:$s + 2]}
       + if length > $s + 2 then {"@odata.nextLink": "\($base)&$skiptoken=\($s + 2)"} else {} end' \
      "$dir/members.json"
    ;;
  "account show")
    if [ ! -r ~/.fake-az-user ]; then
      echo "ERROR: Please run 'az login' to setup account." >&2
      exit 1
    fi
    case "$*" in
      *user.name*) cat ~/.fake-az-user ;;
      *json*)
        jq -n --arg u "$(cat ~/.fake-az-user)" \
          '{user: {name: $u, type: "user"}, tenantId: "0b6e0000-0000-4000-8000-0000000041d2",
            tenantDisplayName: "Corp Test", name: "corp-dev"}'
        ;;
    esac
    ;;
  "login --use-device-code")
    echo "To sign in, use a web browser to open the page https://microsoft.com/devicelogin and enter the code HQ7XK2PLM to authenticate."
    read -r -p "fake az: account to log in as: " a </dev/tty || exit 1
    [ "$a" != cancel ] || exit 1
    echo "$a" >~/.fake-az-user
    ;;
  "logout ") rm -f ~/.fake-az-user ;;
  *)
    echo "fake az: not supported: $*" >&2
    exit 2
    ;;
esac
