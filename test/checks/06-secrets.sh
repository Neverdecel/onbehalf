#!/usr/bin/env bash
# No readable shared secrets (MVP step 6). The gateway holds the canary as its
# model provider key, and the gateway admin key lives in /etc/onbehalf. No
# user may find either one: not in files, not in their environment, and not
# in process command lines (which every user can read).
set -uo pipefail
. /src/test/lib.sh

declare -A SECRETS=(
  ["model-provider-canary"]=${ONBEHALF_CANARY:?}
  ["gateway-admin-key"]=$(</etc/onbehalf/gateway-admin.key)
)

# Search everything a user can read for a string. The string comes in on
# stdin, so it is never on a command line. Prints the files that contain it.
readable_files_with() {
  runuser -l "$1" -c 'grep -rlF -f - --exclude-dir=proc --exclude-dir=sys --exclude-dir=dev / 2>/dev/null'
}

# Self-test: the search must find a marker in a file that everyone can read.
# Without this, a broken search would look like "no leaks".
for u in "${PEOPLE[@]}"; do
  hits=$(printf %s onbehalf-search-control-marker | readable_files_with "$u")
  check "$u: search finds the control marker (self-test)" grep -q search-control.txt <<<"$hits"
done

for name in "${!SECRETS[@]}"; do
  secret=${SECRETS[$name]}
  for u in "${PEOPLE[@]}"; do
    hits=$(printf %s "$secret" | readable_files_with "$u")
    check "$u finds the $name in no readable file" test -z "$hits"
    [ -z "$hits" ] || sed 's/^/        /' <<<"$hits" | head -10

    env_hits=$(as "$u" env | grep -cF -f <(printf %s "$secret"))
    check "$u does not have the $name in their environment" test "$env_hits" = 0
  done

  cmdline_hits=$(grep -lF -f <(printf %s "$secret") /proc/[0-9]*/cmdline 2>/dev/null)
  check "the $name is on no process command line" test -z "$cmdline_hits"
  for f in $cmdline_hits; do printf '        %s: %s\n' "$f" "$(tr '\0' ' ' <"$f" | cut -c1-80)"; done
done

exit $FAILED
