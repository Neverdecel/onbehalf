#!/usr/bin/env bash
# Sets up the host, then runs every check in test/checks/ in order.
# Exit code is non-zero if the setup or one of the checks fails.
set -uo pipefail

. /etc/os-release
echo "host: $PRETTY_NAME, $(opencode --version 2>/dev/null)"

echo "== setup"
/src/test/setup.sh 2>&1 | sed 's/^/  /'
[ "${PIPESTATUS[0]}" = 0 ] || {
  echo "  FAIL  setup"
  exit 1
}

rc=0
for t in /src/test/checks/*.sh; do
  echo "== $(basename "$t")"
  bash "$t" || rc=1
done
exit $rc
