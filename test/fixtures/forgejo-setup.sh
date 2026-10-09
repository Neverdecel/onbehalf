#!/usr/bin/env bash
# Test setup for Git attribution: Forgejo accounts for every user, a shared
# repository team/demo, and for each user what their own login would leave
# behind: a Git identity and a personal token in ~/.git-credentials (0600).
# Passwords and tokens never go on a command line.
set -euo pipefail

FJ=${FORGEJO_URL:?}
api() { # api USER PASSWORD METHOD PATH [JSON]
  curl -fsS -X "$3" "$FJ/api/v1$4" -H 'Content-Type: application/json' \
    --netrc-file <(printf 'machine %s login %s password %s\n' "$(sed 's#.*//##; s#:.*##' <<<"$FJ")" "$1" "$2") \
    ${5:+--data "$5"}
}
root() { api root "${FORGEJO_ADMIN_PASSWORD:?}" "$@"; }

root POST /orgs '{"username":"team"}' >/dev/null
root POST /orgs/team/repos '{"name":"demo","auto_init":true,"default_branch":"main"}' >/dev/null

for u in "$@"; do
  pw=$(od -An -N16 -tx1 /dev/urandom | tr -d " \n")
  root POST /admin/users "{\"username\":\"$u\",\"email\":\"$u@onbehalf.test\",\"password\":\"$pw\",\"must_change_password\":false}" >/dev/null
  root PUT "/repos/team/demo/collaborators/$u" '{"permission":"write"}' >/dev/null
  token=$(api "$u" "$pw" POST "/users/$u/tokens" '{"name":"onbehalf-test","scopes":["write:repository","read:user"]}' | jq -r .sha1)

  home=$(getent passwd "$u" | cut -d: -f6)
  printf 'http://%s:%s@%s\n' "$u" "$token" "${FJ#http://}" \
    | install -o "$u" -g "$(id -gn "$u")" -m 0600 /dev/stdin "$home/.git-credentials"
  runuser -l "$u" -c "git config --global user.name $u && git config --global user.email $u@onbehalf.test \
    && git config --global credential.helper store && git clone -q $FJ/team/demo.git ~/demo" </dev/null
  echo "forgejo: $u can push to team/demo"
done
