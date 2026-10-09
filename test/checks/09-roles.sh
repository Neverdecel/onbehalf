#!/usr/bin/env bash
# Roles: an account is an operator or a user, never both. Operators may run
# onbehalf as root and nothing else. An operator's agent runs in a separate
# runtime account without sudo. Operators promote and demote each other.
set -uo pipefail
. /src/test/lib.sh

SUDOERS=/etc/sudoers.d/onbehalf-operators
AGENTS=/etc/onbehalf/agents

key_of() { echo "$(getent passwd "$1" | cut -d: -f6)/.config/onbehalf/gateway.key"; }
status_of_key() {
  curl -s -o /dev/null -w '%{http_code}' "$ONBEHALF_GATEWAY_URL/v1/models" \
    -H @<(printf 'Authorization: Bearer %s\n' "$1")
}
operator() { id -nG "$1" | tr ' ' '\n' | grep -qx onbehalf-operators; }
not_operator() { ! operator "$1"; }

useradd -m -s /bin/bash oscar
useradd -m -s /bin/bash pia
onbehalf user add oscar >/dev/null 2>&1
oscar_key=$(<"$(key_of oscar)")

# Promote a user: the user setup goes, the operator rule comes.
out=$(onbehalf operator add oscar 2>&1)
check "a user can be promoted to operator" test $? -eq 0
sed 's/^/        /' <<<"$out"
check "oscar is in the operator group" operator oscar
code=$(status_of_key "$oscar_key")
check "the gateway key of the promoted oscar is revoked (HTTP $code)" grep -qxE '401|403' <<<"$code"
check "the key file of oscar is gone" test ! -e "$(key_of oscar)"
check "the sudo rule is root-only" test "$(stat -c '%a %U' "$SUDOERS")" = "440 root"
check "the sudo rule is valid" visudo -cqf "$SUDOERS"

# An operator may run onbehalf as root, and nothing else.
out=$(as oscar "sudo -n onbehalf operator list" 2>&1)
check "an operator can run onbehalf as root" grep -q "oscar" <<<"$out"
check "an operator cannot read root files" denied oscar "sudo -n cat /etc/onbehalf/gateway-admin.key"
check "an operator cannot get a root shell" denied oscar "sudo -n bash -c id"
as oscar "mkdir -p /tmp/evil && echo 'id > /tmp/evil/ran' > /tmp/evil/common.sh"
check "an operator cannot point onbehalf at other code" denied oscar "sudo -n ONBEHALF_LIB=/tmp/evil onbehalf --version"
check "no other code ran as root" test ! -e /tmp/evil/ran
rm -rf /tmp/evil

out=$(onbehalf user enroll oscar 2>&1)
check "an operator does not join at login" \
  grep -q "onbehalf does not enroll oscar: it is an administrator (group onbehalf-operators)" <<<"$out"

# Operators promote and demote each other.
as oscar "sudo -n onbehalf operator add pia" >/dev/null 2>&1
check "an operator can promote another account" operator pia
as oscar "sudo -n onbehalf operator remove pia" >/dev/null 2>&1
check "an operator can demote another operator" not_operator pia
check "a demoted operator cannot run onbehalf as root" denied pia "sudo -n onbehalf operator list"

# The runtime of an operator runs in a separate runtime account, without sudo.
out=$(as oscar "sudo -n onbehalf operator add --runtime oscar" 2>&1)
check "an operator can create their own runtime account" bash -c "id oscar-agent >/dev/null"
sed 's/^/        /' <<<"$out"
check "the runtime account is linked to its operator" grep -qx "oscar-agent oscar" "$AGENTS"
check "the gateway key of the runtime account works" test "$(status_of_key "$(<"$(key_of oscar-agent)")")" = 200
meta=$(admin_get "/key/list?user_id=oscar-agent&return_full_object=true" | jq -r '.keys[0].metadata.agent_of')
check "the gateway key of the runtime account names its operator" test "$meta" = oscar
check "the runtime account has no sudo rule" bash -c 'LC_ALL=C sudo -n -l -U oscar-agent 2>&1 | grep -q "is not allowed to run sudo"'
check "the runtime account cannot run onbehalf as root" denied oscar-agent "sudo -n onbehalf operator list"
check "the runtime account cannot read the home of its operator" denied oscar-agent "ls /home/oscar"
out=$(as oscar "sudo -n onbehalf operator shell -c 'id -un'" 2>&1)
check "the operator opens the runtime account" grep -qx oscar-agent <<<"$out"
out=$(onbehalf doctor --user oscar-agent --model-check 2>&1)
check "the runtime account has model access" grep -q "model access: the model answered" <<<"$out"

# Restart without a shell into the runtime account.
service_pid() { pgrep -u "$1" -n -f 'serve --service'; }
as oscar-agent "opencode service start" >/dev/null 2>&1
before=$(service_pid oscar-agent)
out=$(as oscar "sudo -n onbehalf restart" 2>&1)
check "an operator restarts the service of their runtime account" grep -q "restarted the runtime of oscar-agent" <<<"$out"
check "the agent service runs with a new process" bash -c '[ -n "$2" ] && [ "$1" != "$2" ]' _ "$before" "$(service_pid oscar-agent)"
out=$(as oscar "onbehalf restart" 2>&1)
check "an operator without sudo is sent to the runtime account" grep -q "For your runtime account: sudo onbehalf restart" <<<"$out"
before=$(service_pid alice)
out=$(as alice "onbehalf restart" 2>&1)
check "a user restarts their own service" grep -q "restarted your runtime" <<<"$out"
check "the user's service runs with a new process" bash -c '[ -n "$2" ] && [ "$1" != "$2" ]' _ "$before" "$(service_pid alice)"
check "a user cannot restart the service of another" denied alice "onbehalf restart bob"
out=$(onbehalf restart --all 2>&1)
check "root restarts every running service" grep -q "restarted the runtime of oscar-agent" <<<"$out"

onbehalf operator add pia >/dev/null 2>&1
out=$(as pia "sudo -n onbehalf operator shell oscar -c 'id -un'" 2>&1)
check "an operator cannot open the runtime account of another operator" grep -q "open only your own runtime account" <<<"$out"
check "the other operator did not get in" bash -c '! grep -qx oscar-agent <<<"$1"' _ "$out"
out=$(as pia "sudo -n onbehalf operator shell -c 'id -un'" 2>&1)
check "an operator without an runtime account is told how to make one" grep -q "operator add --runtime pia" <<<"$out"

out=$(onbehalf doctor 2>&1)
check "doctor passes with operators and an runtime account" test $? -eq 0
check "doctor lists the operators" grep -q "operators (may run 'sudo onbehalf'): oscar pia" <<<"$out"
check "doctor names the operator of the runtime account" grep -q "runtime account of the operator oscar" <<<"$out"

out=$(timeout 15 script -qefc "runuser -l oscar -c 'onbehalf login'" /dev/null </dev/null)
check "the login message tells an operator to use the runtime account" grep -q "sudo onbehalf operator shell" <<<"$out"

# OpenCode in an operator account: any OpenCode command starts a background
# service there. Doctor and the login report it; the shell points elsewhere.
runs_opencode() { pgrep -u "$1" -x 'opencode(\.exe)?' >/dev/null; }
as oscar "opencode service start" >/dev/null 2>&1
check "test setup: OpenCode runs in the operator account" runs_opencode oscar
out=$(onbehalf doctor 2>&1)
check "doctor warns about OpenCode in an operator account" grep -q "OpenCode runs in the operator account oscar" <<<"$out"
check "doctor tells the operator how to stop it" grep -q "as oscar: opencode service stop" <<<"$out"
out=$(timeout 15 script -qefc "runuser -l oscar -c 'onbehalf login'" /dev/null </dev/null)
check "the login tells an operator that OpenCode runs in their account" grep -q "OpenCode runs in this operator account" <<<"$out"
check "every login reminds an operator of the runtime account" grep -q "no runtime here. Your runtime account: sudo onbehalf operator shell" <<<"$out"
timeout 30 script -qefc "runuser -l oscar -c 'bash -lic \"opencode service stop\"'" /dev/null </dev/null >/dev/null
sleep 1
check "an operator's login shell can stop OpenCode" bash -c '! pgrep -u oscar -x "opencode(\.exe)?" >/dev/null'
out=$(timeout 30 script -qefc "runuser -l oscar -c 'bash -lic \"opencode models\"'" /dev/null </dev/null)
check "an operator's login shell sends opencode to the runtime account" grep -q "open your runtime account: sudo onbehalf operator shell" <<<"$out"
sleep 1
check "and starts no OpenCode in the operator account" bash -c '! pgrep -u oscar -x "opencode(\.exe)?" >/dev/null'
out=$(onbehalf doctor 2>&1)
check "doctor stops warning once OpenCode is stopped" bash -c '! grep -q "OpenCode runs in the operator account" <<<"$1"' _ "$out"

# An operator who is also a user breaks the core claim; promotion repairs it.
onbehalf user add pia >/dev/null 2>&1
out=$(onbehalf doctor 2>&1)
check "doctor fails for an operator who is also a user" \
  bash -c '[ "$1" -ne 0 ] && grep -q "pia is in the group(s) onbehalf-operators" <<<"$2"' _ $? "$out"
onbehalf operator add pia >/dev/null 2>&1
check "promoting again removes the user setup" test ! -e "$(key_of pia)"

# Demotion: the operator rule goes, the runtime account stays until removed.
out=$(onbehalf operator remove oscar 2>&1)
check "oscar can be demoted" not_operator oscar
check "demotion keeps the runtime account and says how to remove it" grep -q "sudo onbehalf user remove oscar-agent" <<<"$out"
out=$(onbehalf doctor 2>&1)
check "doctor warns about an runtime account without an operator" \
  grep -q "the runtime account oscar-agent is the runtime account of oscar, who is not an operator" <<<"$out"
onbehalf user add oscar >/dev/null 2>&1
check "a demoted operator can become a user again" test "$(status_of_key "$(<"$(key_of oscar)")")" = 200
onbehalf user remove oscar-agent >/dev/null 2>&1
check "removing the runtime account forgets the link" bash -c "! grep -q '^oscar-agent ' $AGENTS"

# Cleanup.
for u in oscar pia; do onbehalf user remove "$u" >/dev/null 2>&1; done
rm -f "$SUDOERS" "$AGENTS"
groupdel onbehalf-operators 2>/dev/null
check "test accounts are removed (test cleanup)" bash -c '! id oscar && ! id pia && ! id oscar-agent' 2>/dev/null

exit $FAILED
