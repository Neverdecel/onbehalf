# shellcheck shell=bash disable=SC2034  # PEOPLE and FAILED are read by the sourcing checks
# Shared helpers for test checks. Checks run as root in a fresh host container,
# after test/setup.sh has installed onbehalf with the users alice and bob.

. /etc/onbehalf/onbehalf.conf

FAILED=0
PEOPLE=(alice bob)

# find arguments that skip /src, the read-only checkout of this repo. It is
# test equipment, not part of the host, and with rootful Docker (CI) it keeps
# the uid of the runner, which can be the uid of a test user.
NOT_SRC=(-path /src -prune -o)

# Run a command as a user, in a clean login shell (no root environment).
# stdin is detached so a command cannot read the calling script.
as() { runuser -l "$1" -c "$2" </dev/null; }

# True if the command fails as that user: denied "USER" "COMMAND".
denied() { ! as "$1" "$2" >/dev/null 2>&1; }

# Gateway admin API call; the key never goes on a command line.
admin_get() {
  curl -fsS "$ONBEHALF_GATEWAY_URL$1" \
    -H @<(printf 'Authorization: Bearer %s\n' "$(</etc/onbehalf/gateway-admin.key)")
}

pass() { printf '  ok    %s\n' "$*"; }
fail() {
  printf '  FAIL  %s\n' "$*"
  FAILED=1
}
check() {
  local msg=$1
  shift
  if "$@"; then pass "$msg"; else fail "$msg"; fi
}
# A check for a known, documented issue: reported, but does not fail the run.
known() {
  local msg=$1
  shift
  if "$@"; then pass "$msg (known issue is fixed: change known to check)"; else printf '  KNOWN %s\n' "$msg"; fi
}
