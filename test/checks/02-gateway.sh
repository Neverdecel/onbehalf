#!/usr/bin/env bash
# Check 2: OpenCode -> gateway -> model use recorded for each user.
set -uo pipefail
. /src/test/lib.sh

for u in "${PEOPLE[@]}"; do
  out=$(as "$u" "cd ~ && timeout 180 opencode run 'say hi'" 2>&1)
  if grep -q onbehalf-mock-ok <<<"$out"; then
    pass "$u: opencode answers through the gateway"
  else
    fail "$u: opencode answers through the gateway"
    printf '%s\n' "$out" | tail -20 | sed 's/^/        /'
  fi
done

# Spend logs are written in batches; wait for them.
for u in "${PEOPLE[@]}"; do
  n=0
  for _ in $(seq 30); do
    n=$(admin_get "/spend/logs?user_id=$u" | jq length)
    [ "$n" -gt 0 ] && break
    sleep 2
  done
  check "$u: gateway recorded model use ($n requests)" test "$n" -gt 0
done

check "bob cannot read alice's gateway key" \
  bash -c '! runuser -l bob -c "cat /home/alice/.config/onbehalf/gateway.key" 2>/dev/null'
check "gateway refuses requests without a key" \
  test "$(curl -s -o /dev/null -w '%{http_code}' "$ONBEHALF_GATEWAY_URL/v1/models")" = 401

exit $FAILED
