#!/usr/bin/env bash
# Attribution (MVP step 8): each user's agent commits and pushes. The commit,
# the push and the model use must all show that user. A fake model makes the
# agent run an exact shell command (see test/fake-model/server.js).
set -uo pipefail
. /src/test/lib.sh

FJ=${FORGEJO_URL:?}
fj() { curl -fsS "$FJ/api/v1$1" --netrc-file <(printf 'machine forgejo login root password %s\n' "${FORGEJO_ADMIN_PASSWORD:?}"); }

# Let the user's agent run COMMAND in ~/demo.
agent_run() {
  as "$1" "cd ~/demo && timeout 180 opencode run --auto -m onbehalf/agent-model 'RUN: $2'" 2>&1
}

# Login of the Forgejo user that pushed a commit with MARKER in its message,
# from USER's activity feed: pusher_of USER MARKER [WAIT_SECONDS].
# Forgejo writes the feed asynchronously, so a positive lookup waits for it.
pusher_of() {
  local login
  for _ in $(seq "${3:-20}"); do
    login=$(fj "/users/$1/activities/feeds?only-performed-by=true&limit=50" \
      | jq -r --arg m "$2" '.[] | select(.op_type == "commit_repo" and (.content | contains($m))) | .act_user.login' | head -1)
    [ -n "$login" ] && break
    sleep 1
  done
  echo "$login"
}

for u in "${PEOPLE[@]}"; do
  marker="attribution-$u-$(date +%s%N)"
  out=$(agent_run "$u" "echo $marker > $u.txt && git add $u.txt && git commit -q -m $marker && git push -q origin HEAD:refs/heads/$marker")
  if grep -q onbehalf-agent-done <<<"$out"; then
    pass "$u's agent ran the commit and push"
  else
    fail "$u's agent ran the commit and push"
    tail -15 <<<"$out" | sed 's/^/        /'
    continue
  fi

  commit=$(fj "/repos/team/demo/commits?sha=$marker&limit=1" | jq '.[0]')
  check "the commit on Forgejo has $u as author" \
    test "$(jq -r .commit.author.email <<<"$commit")" = "$u@onbehalf.test"
  check "Forgejo links the commit to the account $u" test "$(jq -r .author.login <<<"$commit")" = "$u"
  check "Forgejo records $u as the pusher" test "$(pusher_of "$u" "$marker")" = "$u"

  n=$(admin_get "/spend/logs?user_id=$u" | jq '[.[] | select(.model_group == "agent-model")] | length')
  for _ in $(seq 15); do
    [ "$n" -gt 0 ] && break
    sleep 2
    n=$(admin_get "/spend/logs?user_id=$u" | jq '[.[] | select(.model_group == "agent-model")] | length')
  done
  check "the gateway records the agent's model use for $u ($n requests)" test "$n" -gt 0
done

# The author of a commit is only Git config. Bob's agent claims to be alice:
# Forgejo still shows bob as the pusher, because the push used bob's token.
marker="forged-author-$(date +%s%N)"
out=$(agent_run bob "echo $marker > forged.txt && git add forged.txt && git -c user.name=alice -c user.email=alice@onbehalf.test commit -q -m $marker && git push -q origin HEAD:refs/heads/$marker")
check "bob's agent pushed a commit with alice as author (test setup)" grep -q onbehalf-agent-done <<<"$out"
check "the forged commit shows alice as author" \
  test "$(fj "/repos/team/demo/commits?sha=$marker&limit=1" | jq -r '.[0].commit.author.email')" = alice@onbehalf.test
check "Forgejo records bob, not alice, as the pusher of the forged commit" test "$(pusher_of bob "$marker")" = bob
# Bob's feed entry exists now, so the feed queue has been processed.
check "alice has no push of the forged commit" test -z "$(pusher_of alice "$marker" 1)"

exit $FAILED
