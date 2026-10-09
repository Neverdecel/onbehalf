#!/usr/bin/env bash
# Users follow an Entra group (onbehalf user sync). A fake Azure CLI stands
# in for Entra. The operator's own az login reads the group, users are
# linked by Entra object id, an existing account is never taken over without
# the operator's word, and nobody is removed without --remove.
set -uo pipefail
. /src/test/lib.sh

E=/tmp/fake-entra
MAP=/etc/onbehalf/entra.map
GID=11111111-0000-4000-8000-000000000000
oid() { printf '22222222-0000-4000-8000-%012d' "$1"; }
DAVE=$(oid 1) ERIN=$(oid 2) GUEST=$(oid 3) FRANK=$(oid 4) GINA=$(oid 5)
GUEST_UPN='guest_gmail.com#EXT#@corp.test'

member() { jq -nc --arg id "$1" --arg upn "$2" --argjson on "${3:-true}" '{id: $id, userPrincipalName: $upn, accountEnabled: $on}'; }
set_members() { jq -s . >"$E/members.json"; }
esync() { as ops "sudo onbehalf user sync $*" 2>&1; }
exists() { id "$1" >/dev/null 2>&1; }
gone() { ! exists "$1"; }

# The operator "ops" may run onbehalf as root, and nothing else.
install -d -m 0755 "$E"
install -m 0666 /dev/null "$E/calls.log"
echo "{\"agent-vm-users\": \"$GID\"}" >"$E/groups.json"
install -m 0755 /src/test/fixtures/fake-az.sh /usr/local/bin/az
useradd -m -s /bin/bash ops
echo 'ops ALL=(root) NOPASSWD: /usr/local/bin/onbehalf' >/etc/sudoers.d/onbehalf-ops
chmod 0440 /etc/sudoers.d/onbehalf-ops
# A local account that has the name of an Entra member, but may be someone else.
useradd -m -s /bin/bash gina

{
  member "$DAVE" Dave.Jones@corp.test
  member "$ERIN" erin@corp.test
  member "$GUEST" "$GUEST_UPN"
  member "$FRANK" frank@corp.test false
  member "$GINA" gina@corp.test
} | set_members

out=$(esync --group agent-vm-users)
check "the first sync reports the members it cannot add" test $? -ne 0
sed 's/^/        /' <<<"$out"
check "sync reads Entra with the operator's own az login" grep -q "read as ops" <<<"$out"
check "every az call ran as the operator, never as root" bash -c "! grep -qv '^ops ' $E/calls.log"
check "all members are read across pages" grep -q "5 member(s)" <<<"$out"
check "Dave.Jones@corp.test becomes the account dave-jones" exists dave-jones
check "erin@corp.test becomes the account erin" exists erin
check "dave-jones is linked by Entra object id" grep -qx "dave-jones $DAVE Dave.Jones@corp.test" "$MAP"
key_meta=$(admin_get "/key/list?user_id=dave-jones&return_full_object=true" | jq -r '.keys[0].metadata.entra_object_id')
check "the gateway key of dave-jones carries the Entra object id" test "$key_meta" = "$DAVE"
check "a disabled Entra account gets no account" gone frank
check "a guest UPN is not turned into an account name" grep -qF "$GUEST_UPN: no valid account name" <<<"$out"
check "the fix for the guest names the object id" grep -q -- "--entra-id $GUEST <name>" <<<"$out"
check "the existing account gina is not taken over" bash -c "! grep -q '^gina ' $MAP"
check "sync names the command to link gina" \
  grep -q "if gina is gina@corp.test: sudo onbehalf user add --entra-id $GINA gina" <<<"$out"
check "alice and bob are not touched" grep -q "not linked to Entra, sync does not change them: alice bob" <<<"$out"
check "the map is owned by root and readable by all" test "$(stat -c '%a %U' "$MAP")" = "644 root"

# The operator links gina and the guest by hand; then the sync passes.
onbehalf user add --entra-id "$GINA" gina >/dev/null 2>&1
check "the operator can link the existing account gina" grep -q "^gina $GINA " "$MAP"
onbehalf user add --entra-id "$GUEST" guest1 >/dev/null 2>&1
check "the operator can choose a name for the guest" grep -q "^guest1 $GUEST " "$MAP"
out=$(onbehalf user add --entra-id "$GINA" henk 2>&1)
check "one Entra account cannot be linked to two users" grep -q "is linked to gina already" <<<"$out"
check "a refused link creates no account" gone henk

out=$(esync)
check "the second sync passes, with the saved group" test $? -eq 0
check "sync fills in the UPN of a user linked by hand" grep -qx "gina $GINA gina@corp.test" "$MAP"
out=$(onbehalf doctor 2>&1)
check "doctor passes with users linked to Entra" test $? -eq 0
check "doctor shows the Entra group" grep -q "users follow the Entra group agent-vm-users" <<<"$out"

# Status: the Azure CLI must be logged in as the user's own Entra account.
as dave-jones "echo dave.jones@corp.test > ~/.fake-az-user"
out=$(as dave-jones "onbehalf status" 2>&1)
check "status shows the Entra account of dave-jones" grep -q "Entra account: Dave.Jones@corp.test" <<<"$out"
check "status accepts the matching az login (case does not matter)" \
  bash -c '! grep -q "not as your Entra account" <<<"$1"' _ "$out"
as dave-jones "echo shared-svc@corp.test > ~/.fake-az-user"
out=$(as dave-jones "onbehalf status" 2>&1)
check "status warns when az is logged in as another account" \
  grep -q "Azure CLI: logged in as shared-svc@corp.test, not as your Entra account Dave.Jones@corp.test" <<<"$out"

# Erin leaves the group; dave is disabled in Entra.
{
  member "$DAVE" Dave.Jones@corp.test false
  member "$GUEST" "$GUEST_UPN"
  member "$FRANK" frank@corp.test false
  member "$GINA" gina@corp.test
} | set_members

out=$(esync --remove --dry-run)
check "a dry run names who would be removed" \
  bash -c 'grep -q "would remove erin (erin@corp.test)" <<<"$1" && grep -q "would remove dave-jones" <<<"$1"' _ "$out"
check "a dry run keeps erin" exists erin
check "a dry run keeps dave-jones" exists dave-jones

out=$(esync)
check "without --remove, sync only warns" grep -q "erin (erin@corp.test) is not an active member" <<<"$out"
check "without --remove, erin keeps her account" exists erin

erin_key=$(</home/erin/.config/onbehalf/gateway.key)
out=$(esync --remove)
check "sync --remove succeeds" test $? -eq 0
check "erin, who left the group, is removed" gone erin
check "dave-jones, disabled in Entra, is removed" gone dave-jones
code=$(curl -s -o /dev/null -w '%{http_code}' "$ONBEHALF_GATEWAY_URL/v1/models" \
  -H @<(printf 'Authorization: Bearer %s\n' "$erin_key"))
check "erin's gateway key is revoked (HTTP $code)" grep -qxE '401|403' <<<"$code"
check "the Entra links of removed users are gone" bash -c "! grep -qE '^(erin|dave-jones) ' $MAP"
check "alice, not linked to Entra, stays" exists alice
check "bob, not linked to Entra, stays" exists bob
check "gina, an active member, stays" exists gina
check "guest1, an active member, stays" exists guest1

# Signals that must never offboard anyone.
echo '[]' >"$E/members.json"
out=$(esync --remove)
check "an empty group stops the sync" bash -c '[ "$1" -ne 0 ] && grep -q "no user members" <<<"$2"' _ $? "$out"
check "an empty group removes nobody" exists gina

{
  member "$GUEST" "$GUEST_UPN"
  member "$GINA" gina@corp.test
} | set_members
touch "$E/fail"
out=$(esync --remove)
check "a failed Entra read stops the sync" test $? -ne 0
check "the error shows what az said" grep -q "AADSTS700082" <<<"$out"
check "a failed Entra read removes nobody" exists gina
rm "$E/fail"

out=$(onbehalf user sync 2>&1)
check "as plain root, sync asks for sudo or a member list" bash -c '[ "$1" -ne 0 ] && grep -q -- "--from -" <<<"$2"' _ $? "$out"

# A member list from elsewhere, in the format of `az ad group member list`.
calls=$(wc -l <"$E/calls.log")
out=$(jq '[.[] | del(.accountEnabled) + {"@odata.type": "#microsoft.graph.user"}]
  + [{"@odata.type": "#microsoft.graph.group", "id": "33333333-0000-4000-8000-000000000000"}]' "$E/members.json" \
  | onbehalf user sync --from - 2>&1)
check "sync takes a member list on stdin" test $? -eq 0
check "a member list skips nested group objects" grep -q "2 member(s), read from /dev/stdin" <<<"$out"
check "a member list on stdin does not call az" test "$(wc -l <"$E/calls.log")" = "$calls"

# In a UTF-8 locale, bash can change İ to i. The name rules must use ASCII
# rules, so HENRİ@corp.test does not become the account henri.
out=$(jq --arg id "$(oid 6)" '[.[] | del(.accountEnabled)] + [{id: $id, userPrincipalName: "HENRİ@corp.test"}]' \
  "$E/members.json" | LC_ALL=C.UTF-8 onbehalf user sync --from - 2>&1)
check "a UPN with a letter that is not ASCII gets no account" gone henri
check "sync names the UPN with no valid account name" grep -qF "HENRİ@corp.test: no valid account name" <<<"$out"

# Cleanup.
for u in gina guest1; do onbehalf user remove "$u" >/dev/null 2>&1; done
userdel -r ops 2>/dev/null
rm -rf "$E" /usr/local/bin/az /etc/sudoers.d/onbehalf-ops /etc/onbehalf/entra.conf "$MAP"
check "Entra test users are removed (test cleanup)" bash -c '! id gina && ! id guest1 && ! id ops' 2>/dev/null

exit $FAILED
