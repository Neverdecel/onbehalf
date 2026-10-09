#!/usr/bin/env bash
# Concurrency: several users, each with several sessions at the same time.
# Every terminal, `opencode run` and TUI tab of a user is a session of that
# user's one background service. Sessions at the same time stay with their
# user, and a restart of one service stops only that user's sessions.
set -uo pipefail
. /src/test/lib.sh

RID=$(date +%s)
TMP=$(mktemp -d)
chmod 0755 "$TMP"

# Start one session of USER as run N in the background. The agent writes the
# time when its command starts and ends to ~/conc-RID-N.{start,end}.
start_run() {
  local u=$1 n=$2 secs=$3 m="conc-$RID-$2"
  as "$u" "cd ~ && timeout 180 opencode run --auto -m onbehalf/agent-model --title $m 'RUN: date +%s.%N >~/$m.start && sleep $secs && date +%s.%N >~/$m.end'" >"$TMP/$n.out" 2>&1 &
}
mark() { cat "/home/$1/conc-$RID-$2.$3" 2>/dev/null; }
serve_pid() { pgrep -u "$1" -f 'serve --service'; }
titles() { as "$1" "opencode session list" 2>/dev/null | grep -o "conc-$RID-[0-9]*" | sort -u | tr '\n' ' '; }
# Gateway requests of USER whose prompt contains MARKER.
logged() { admin_get "/spend/logs?user_id=$1" | jq --arg m "$2" '[.[] | select(tostring | contains($m))] | length'; }

for u in "${PEOPLE[@]}"; do as "$u" "opencode service start" >/dev/null 2>&1; done
declare -A pid want
for u in "${PEOPLE[@]}"; do pid[$u]=$(serve_pid "$u"); done

# Three sessions of each user at the same time: runs 1-3 alice, 4-6 bob.
owner() { if [ "$1" -le 3 ]; then echo alice; else echo bob; fi; }
for n in 1 2 3 4 5 6; do
  start_run "$(owner "$n")" "$n" 5
  want[$(owner "$n")]+="conc-$RID-$n "
done
wait

starts=() ends=()
for n in 1 2 3 4 5 6; do
  u=$(owner "$n")
  if grep -q onbehalf-agent-done "$TMP/$n.out"; then
    pass "$u's session $n finished"
  else
    fail "$u's session $n finished"
    tail -10 "$TMP/$n.out" | sed 's/^/        /'
  fi
  starts+=("$(mark "$u" "$n" start)") ends+=("$(mark "$u" "$n" end)")
done
last_start=$(printf '%s\n' "${starts[@]}" | sort -n | tail -1)
first_end=$(printf '%s\n' "${ends[@]}" | sort -n | head -1)
check "all six sessions ran at the same time (last start $last_start < first end $first_end)" \
  awk -v s="$last_start" -v e="$first_end" 'BEGIN { exit !(s != "" && e != "" && s < e) }'

for u in "${PEOPLE[@]}"; do
  check "$u's sessions used one running service" test "$(serve_pid "$u")" = "${pid[$u]}"
  check "$u's session list has exactly their own sessions ($(titles "$u"))" test "$(titles "$u")" = "${want[$u]}"
done

# Each session's model use is recorded under its own user only.
for n in 1 2 3 4 5 6; do
  u=$(owner "$n") other=alice
  [ "$u" = alice ] && other=bob
  c=0
  for _ in $(seq 15); do
    c=$(logged "$u" "conc-$RID-$n.start")
    [ "$c" -gt 0 ] && break
    sleep 2
  done
  check "the gateway records session $n under $u ($c requests)" test "$c" -gt 0
  check "the gateway records nothing of session $n under $other" test "$(logged "$other" "conc-$RID-$n.start")" = 0
done

# A service restart stops every running session of that user, in every
# terminal and tab, but no session of another user.
start_run alice 7 30
start_run alice 8 30
start_run bob 9 10
for _ in $(seq 60); do
  [ -n "$(mark alice 7 start)" ] && [ -n "$(mark alice 8 start)" ] && [ -n "$(mark bob 9 start)" ] && break
  sleep 0.5
done
check "alice and bob have running sessions before the restart (test setup)" \
  test -n "$(mark alice 7 start)" -a -n "$(mark alice 8 start)" -a -n "$(mark bob 9 start)"
as alice "opencode service restart" >/dev/null 2>&1
wait
check "the restart stopped alice's session 7" bash -c '! grep -q onbehalf-agent-done "$1"' _ "$TMP/7.out"
check "the restart stopped alice's session 8" bash -c '! grep -q onbehalf-agent-done "$1"' _ "$TMP/8.out"
check "bob's session finished during alice's restart" grep -q onbehalf-agent-done "$TMP/9.out"
check "alice's service runs again after the restart" test -n "$(serve_pid alice)"
check "alice keeps her stopped sessions" grep -q "conc-$RID-7 conc-$RID-8" <<<"$(titles alice)"

rm -rf "$TMP"
rm -f /home/alice/conc-"$RID"-* /home/bob/conc-"$RID"-*
exit $FAILED
