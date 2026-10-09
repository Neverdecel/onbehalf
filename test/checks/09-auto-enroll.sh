#!/usr/bin/env bash
# Auto-enroll: every user who can log in joins at their first SSH login.
# The test host has no sshd, so the test calls the hook the way pam_exec does:
# as root, with an empty environment and PAM_TYPE and PAM_USER. An account of
# the Entra login is played by a local account that is named by UPN and has a
# uid too large for PORT_BASE + uid.
set -uo pipefail
. /src/test/lib.sh

PAM=/etc/pam.d/sshd
STATE=/var/lib/onbehalf/enrolled
LOG=/var/log/onbehalf-enroll.log
CAROL=carol.jones@corp.test
ONB=/usr/local/bin/onbehalf

login() { env -i PAM_TYPE=open_session PAM_USER="$1" PAM_SERVICE=sshd "$ONB" user enroll --pam; }
key_of() { echo "$(getent passwd "$1" | cut -d: -f6)/.config/onbehalf/gateway.key"; }
joined() { [ -s "$(key_of "$1")" ]; }
key_works() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' "$ONBEHALF_GATEWAY_URL/v1/models" \
    -H @<(printf 'Authorization: Bearer %s\n' "$(<"$(key_of "$1")")"))
  [ "$code" = 200 ]
}
keys_of() { admin_get "/key/list?user_id=$(jq -rn --arg u "$1" '$u | @uri')" | jq '.keys | length'; }
# A uid above 25535 does not fit PORT_BASE + uid. Stay below 65536: the uid
# range of rootless Docker.
upn_account() {
  local uid=50000
  while getent passwd "$uid" >/dev/null || getent group "$uid" >/dev/null; do uid=$((uid + 1)); done
  useradd -m --badname -s /bin/bash -u "$uid" "$1" 2>&1 | grep -v 'outside of the UID_MIN'
}

install -d -m 0755 /etc/pam.d
printf 'session required pam_env.so\n' >"$PAM"
admin_group=$(getent group sudo >/dev/null && echo sudo || echo wheel)

out=$(onbehalf auto-enroll on --exclude breakglass 2>&1)
check "auto-enroll on succeeds" test $? -eq 0
sed 's/^/        /' <<<"$out"
check "sshd runs the enrollment as a session hook that never blocks a login" \
  grep -qx "session optional pam_exec.so quiet $(command -v timeout) 90 $ONB user enroll --pam" "$PAM"
onbehalf auto-enroll on >/dev/null 2>&1
check "turning it on again adds no second hook" test "$(grep -c 'user enroll --pam' "$PAM")" = 1
check "the PAM file keeps its own lines" grep -qx 'session required pam_env.so' "$PAM"
check "the exclude list is kept when not given again" grep -q 'ONBEHALF_ENROLL_EXCLUDE=breakglass' /etc/onbehalf/enroll.conf

# First login of an Entra account: it joins.
upn_account "$CAROL"
chmod 0755 "$(getent passwd "$CAROL" | cut -d: -f6)"
login "$CAROL"
check "the login hook succeeds" test $? -eq 0
check "$CAROL joined at the first login" joined "$CAROL"
check "the gateway key of $CAROL works" key_works "$CAROL"
check "the gateway key is private" test "$(stat -c '%a %U' "$(key_of "$CAROL")")" = "600 $CAROL"
check "the home directory became private" test "$(stat -c %a "/home/$CAROL")" = 700
port=$(awk -v n="$CAROL" '$1 == n { print $2 }' /etc/onbehalf/ports)
check "a uid too large for PORT_BASE + uid gets a valid service port ($port)" \
  bash -c '[ -n "$1" ] && [ "$1" -gt "$2" ] && [ "$1" -le 65535 ]' _ "$port" "$ONBEHALF_PORT_BASE"
upn=$(admin_get "/key/list?user_id=carol.jones%40corp.test&return_full_object=true" | jq -r '.keys[0].metadata.entra_upn')
check "the gateway key carries the UPN" test "$upn" = "$CAROL"
check "the login is logged" grep -q "$CAROL enrolled in onbehalf" "$LOG"
out=$(onbehalf doctor --model-check --user "$CAROL" 2>&1)
check "doctor passes with a user who joined at login" test $? -eq 0
check "doctor shows that auto-enroll is on" grep -q "auto-enroll is on" <<<"$out"
check "doctor checks $CAROL, who getent may not list" grep -q "^$CAROL" <<<"$out"
check "$CAROL has model access" grep -q "model access: the model answered" <<<"$out"

before=$(sha256sum "$(key_of "$CAROL")")
touch -d '2 days ago' "$STATE/$CAROL"
login "$CAROL"
check "a later login keeps the key" test "$(sha256sum "$(key_of "$CAROL")")" = "$before"
check "a later login makes no second gateway key" test "$(keys_of "$CAROL")" = 1
check "a later login records the login time" test -z "$(find "$STATE/$CAROL" -mmin +5)"

# Administrators and excluded accounts never join; the login still succeeds.
useradd -m -s /bin/bash -G "$admin_group" dana
useradd -m -s /bin/bash erik
echo 'erik ALL=(root) /usr/bin/true' >/etc/sudoers.d/erik
chmod 0440 /etc/sudoers.d/erik
useradd -m -s /bin/bash breakglass
for u in dana erik breakglass root; do
  login "$u"
  check "the login of $u succeeds" test $? -eq 0
done
check "a member of $admin_group does not join" bash -c '! [ -e /home/dana/.config/onbehalf/gateway.key ]'
check "an account that may use sudo does not join" bash -c '! [ -e /home/erik/.config/onbehalf/gateway.key ]'
check "an excluded account does not join" bash -c '! [ -e /home/breakglass/.config/onbehalf/gateway.key ]'
check "root does not join" bash -c '! [ -e /root/.config/onbehalf/gateway.key ] && ! [ -e /var/lib/onbehalf/enrolled/root ]'
out=$(onbehalf user enroll erik 2>&1)
check "the operator sees why an account does not join" grep -q "onbehalf does not enroll erik: it is an administrator (it can use sudo)" <<<"$out"

# A user an operator added is never marked as joined at login.
login alice
check "alice, added by the operator, is not pruned later" test ! -e "$STATE/alice"

# A failure does not block the login; it is logged, and the next login retries.
cp -p /etc/onbehalf/gateway-admin.key /tmp/admin.key
printf 'sk-wrong' >/etc/onbehalf/gateway-admin.key
useradd -m -s /bin/bash frank
login frank
check "the login succeeds when the enrollment fails" test $? -eq 0
check "frank did not join while the gateway refused" bash -c '! [ -e /home/frank/.config/onbehalf/gateway.key ]'
check "the failure is logged" grep -q "frank could not enroll in onbehalf" "$LOG"
cp -p /tmp/admin.key /etc/onbehalf/gateway-admin.key
rm -f /tmp/admin.key
login frank
check "the next login of frank joins" key_works frank

# Parallel first logins of two accounts with large uids get different ports.
upn_account gina@corp.test
upn_account hank@corp.test
login gina@corp.test &
login hank@corp.test &
wait
pg=$(awk '$1 == "gina@corp.test" { print $2 }' /etc/onbehalf/ports)
ph=$(awk '$1 == "hank@corp.test" { print $2 }' /etc/onbehalf/ports)
check "parallel first logins both join" bash -c 'grep -q . "$1" && grep -q . "$2"' _ "$(key_of gina@corp.test)" "$(key_of hank@corp.test)"
check "parallel first logins get different ports ($pg, $ph)" bash -c '[ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ]' _ "$pg" "$ph"

# Prune: users who joined at login and stopped logging in lose their key.
touch -d '40 days ago' "$STATE/$CAROL" "$STATE/hank@corp.test"
as hank@corp.test "nohup sleep 300 >/dev/null 2>&1 &"
out=$(onbehalf user prune --dry-run 2>&1)
check "a dry run names who would lose the key" grep -q "would revoke the gateway key of $CAROL" <<<"$out"
check "a dry run keeps the key" key_works "$CAROL"
carol_key=$(<"$(key_of "$CAROL")")
out=$(onbehalf user prune 2>&1)
check "prune succeeds" test $? -eq 0
sed 's/^/        /' <<<"$out"
code=$(curl -s -o /dev/null -w '%{http_code}' "$ONBEHALF_GATEWAY_URL/v1/models" \
  -H @<(printf 'Authorization: Bearer %s\n' "$carol_key"))
check "the gateway key of the idle $CAROL is revoked (HTTP $code)" grep -qxE '401|403' <<<"$code"
check "the key file of $CAROL is gone" test ! -e "$(key_of "$CAROL")"
check "the files of $CAROL stay" test -d "/home/$CAROL/.config/opencode"
check "a user with running processes counts as active" key_works hank@corp.test
check "a user who logged in recently keeps the key" key_works gina@corp.test
check "a user added by the operator keeps the key" key_works alice
login "$CAROL"
check "the next login of $CAROL gives a new key" key_works "$CAROL"
check "$CAROL keeps the service port" test "$(awk -v n="$CAROL" '$1 == n { print $2 }' /etc/onbehalf/ports)" = "$port"

# Off: no more enrollments; users who joined stay.
out=$(onbehalf auto-enroll off 2>&1)
check "auto-enroll off succeeds" test $? -eq 0
check "auto-enroll off removes the hook" bash -c "! grep -q 'onbehalf' $PAM"
check "auto-enroll off keeps the other PAM lines" grep -qx 'session required pam_env.so' "$PAM"
useradd -m -s /bin/bash ivan
login ivan
check "with auto-enroll off, a login does not join" bash -c '! [ -e /home/ivan/.config/onbehalf/gateway.key ]'
check "users who joined stay" key_works "$CAROL"

# Removal of a user who joined at login.
out=$(onbehalf user remove "$CAROL" 2>&1)
check "$CAROL can be removed" test $? -eq 0
check "removal frees the service port of $CAROL" bash -c "! grep -q '^$CAROL ' /etc/onbehalf/ports"
check "removal forgets the login record of $CAROL" test ! -e "$STATE/$CAROL"

# Cleanup.
pkill -u hank@corp.test 2>/dev/null
for u in frank gina@corp.test hank@corp.test; do onbehalf user remove "$u" >/dev/null 2>&1; done
for u in dana erik breakglass ivan; do userdel -r "$u" 2>/dev/null; done
rm -f /etc/sudoers.d/erik "$PAM" /etc/onbehalf/enroll.conf "$LOG"
check "test users are removed (test cleanup)" \
  bash -c '! id frank && ! id gina@corp.test && ! id hank@corp.test && ! id dana' 2>/dev/null
check "no ports are left for test users (test cleanup)" bash -c '! grep -q . /etc/onbehalf/ports 2>/dev/null'

exit $FAILED
