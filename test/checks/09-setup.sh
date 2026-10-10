#!/usr/bin/env bash
# Exercise terminal setup with operator commands replaced by bounded local stubs.
# Also runs directly: bash test/checks/09-setup.sh. No root or gateway is needed.
set -euo pipefail
self=$(readlink -f "$0")
src=$(dirname "$(dirname "$(dirname "$self")")")
original_home=$HOME

if [ $# -gt 0 ]; then
  ONBEHALF_LIB="$src/lib/onbehalf"
  . "$ONBEHALF_LIB/common.sh"
  . "$ONBEHALF_LIB/ui.sh"
  . "$ONBEHALF_LIB/cmd-init.sh"
  . "$ONBEHALF_LIB/cmd-setup.sh"
  . "$ONBEHALF_LIB/enroll.sh"
  . "$ONBEHALF_LIB/roles.sh"
  . "$ONBEHALF_LIB/tools.sh"
  . "$ONBEHALF_LIB/harness.sh"
  . "$ONBEHALF_LIB/harness-opencode.sh"
  need_root() { [ "$TEST_UID" = 0 ] || die "this command must run as root"; }
  id() {
    if [ "$*" = -u ]; then
      echo "$TEST_UID"
    elif [ "${*: -1}" = admin ]; then
      if [ "$1" = -u ]; then echo 1001; fi
    else
      return 1
    fi
  }
  privileged_groups_of() { echo sudo; }
  opencode() { :; }
  # The work-tool wizard has its own check (11-work-tools.sh).
  # shellcheck disable=SC2034 # read by cmd_login
  tools_offer() { TOOLS_OFFERED=${TEST_OFFER:-no}; }
  tools_refresh_later() { echo refresh >>"$TEST_CALLS"; }
  if [ "${TEST_OPENCODE:-yes}" = missing ]; then
    command() {
      if [ "$*" = "-v opencode" ]; then return 1; fi
      builtin command "$@"
    }
  fi
  curl() { [ "${TEST_GATEWAY:-up}" = up ]; }
  people() { echo alice; }
  doctor_model_access() {
    echo "model $1" >>"$TEST_CALLS"
    [ "${TEST_MODEL_FAIL:-no}" = no ]
  }
  cmd_init() {
    echo init >>"$TEST_CALLS"
    [ "${TEST_INIT_FAIL:-no}" = no ] || exit 1
    mkdir -p "$ONBEHALF_ETC"
    printf 'ONBEHALF_GATEWAY_URL=http://gateway.test\nONBEHALF_STACK=%q\n' "$TEST_STACK" >"$ONBEHALF_ETC/onbehalf.conf"
    printf 'test-key' >"$ONBEHALF_ETC/gateway-admin.key"
  }
  cmd_stack_install() {
    [ "$1" = --no-restart ]
    echo stack >>"$TEST_CALLS"
    mkdir -p "$ONBEHALF_STACK/current"
  }
  cmd_user_add() { echo "users $*" >>"$TEST_CALLS"; }
  cmd_auto_enroll() { echo "auto-enroll $*" >>"$TEST_CALLS"; }
  cmd_doctor() {
    echo doctor >>"$TEST_CALLS"
    [ "${TEST_DOCTOR_FAIL:-no}" = no ] || exit 1
  }
  case $1 in
    --wizard) cmd_setup ;;
    --login) cmd_login ;;
    --profile)
      onbehalf() { echo "$*" >>"$TEST_CALLS"; }
      . "$ONBEHALF_LIB/login-profile.sh"
      ;;
    *) exit 2 ;;
  esac
  exit 0
fi

mkdir -p /tmp/opencode
tmp=$(mktemp -d /tmp/opencode/onbehalf-setup.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
export ONBEHALF_ETC="$tmp/etc" TEST_STACK="$tmp/stack" TEST_CALLS="$tmp/calls" TEST_UID=0
mkdir -p "$tmp/source/opencode"
printf '{}\n' >"$tmp/source/opencode/opencode.json"
: >"$TEST_CALLS"

check() {
  local message=$1
  shift
  "$@" || {
    printf '  FAIL  %s\n' "$message"
    exit 1
  }
  printf '  ok    %s\n' "$message"
}
terminal() { timeout 15 script -qefc "bash --noprofile --norc '$self' '$1'" /dev/null; }

if out=$(bash "$self" --wizard </dev/null 2>&1); then
  check "setup rejects non-terminal input" false
fi
check "non-terminal setup changes nothing" test ! -s "$TEST_CALLS"
check "non-terminal setup explains the script path" grep -q 'For scripts, use the operator commands' <<<"$out"

out=$(printf 'no\n' | terminal --wizard)
check "cancel changes nothing" test ! -s "$TEST_CALLS"
check "setup explains the host administrator and user roles" \
  bash -c 'grep -q "You are the host administrator" <<<"$1" && grep -q "Users are usual accounts" <<<"$1"' _ "$out"
check "setup separates gateway and provider credentials before it asks" \
  bash -c 'grep -q "Model provider keys .* onbehalf never asks for them" <<<"$1" && grep -q LITELLM_MASTER_KEY <<<"$1"' _ "$out"

out=$(printf 'yes\n' | TEST_UID=1001 terminal --wizard 2>&1) && rc=0 || rc=$?
check "ordinary users cannot run host setup" test "$rc" -ne 0
check "denied setup changes nothing" test ! -s "$TEST_CALLS"

# Prerequisite handoff: stop before any change, say what to do, and how to continue.
out=$(printf 'yes\nno\n' | terminal --wizard 2>&1) && rc=0 || rc=$?
check "a gateway that is not ready pauses setup" test "$rc" -ne 0
check "a paused setup changes nothing" test ! -s "$TEST_CALLS"
check "the handoff shows how to set up the gateway" \
  bash -c 'grep -q "examples/gateway" <<<"$1" && grep -q "Azure AI Foundry" <<<"$1"' _ "$out"
check "the handoff shows how to continue" grep -q 'continue with: sudo onbehalf setup' <<<"$out"
out=$(printf 'yes\nyes\n' | TEST_OPENCODE=missing terminal --wizard 2>&1) && rc=0 || rc=$?
check "missing OpenCode pauses setup" test "$rc" -ne 0
check "missing OpenCode changes nothing" test ! -s "$TEST_CALLS"
check "the handoff names OpenCode" grep -q 'OpenCode is not installed for the full host' <<<"$out"
out=$(printf 'yes\nyes\n' | TEST_INIT_FAIL=yes terminal --wizard 2>&1) && rc=0 || rc=$?
check "a failed gateway connection pauses setup" test "$rc" -ne 0
check "a failed gateway connection stops before the stack" test "$(cat "$TEST_CALLS")" = init
check "a failed gateway connection shows how to continue" grep -q 'Setup paused' <<<"$out"
: >"$TEST_CALLS"

out=$(printf 'yes\nyes\n%s\nyes\n\nalice bob\nyes\nno\n' "$tmp/source" | terminal --wizard)
check "fresh setup calls the existing commands in order" test "$(cat "$TEST_CALLS")" = $'init\nstack\nusers alice bob\ndoctor'
check "fresh setup reports completion" grep -q 'Host setup is complete' <<<"$out"
check "setup offers auto-enroll, off by default" grep -q 'Turn on auto-enroll? (yes/no) \[no\]' <<<"$out"
check "declined model check sends no request and says so" grep -q 'model access: not checked' <<<"$out"
before=$(sha256sum "$ONBEHALF_ETC/gateway-admin.key")
: >"$TEST_CALLS"
out=$(printf 'yes\n\n\nno\n' | terminal --wizard)
check "repeat setup keeps the gateway and stack, and can skip users" test "$(cat "$TEST_CALLS")" = doctor
check "repeat setup keeps the admin key" test "$(sha256sum "$ONBEHALF_ETC/gateway-admin.key")" = "$before"

: >"$TEST_CALLS"
out=$(printf 'yes\n' | TEST_GATEWAY=down terminal --wizard 2>&1) && rc=0 || rc=$?
check "repeat setup pauses when the saved gateway does not answer" test "$rc" -ne 0
check "a gateway that stopped causes no operator calls" test ! -s "$TEST_CALLS"

# Model access: one request as the first user, only with consent. Reported
# apart from the host checks, and a refusal fails setup.
out=$(printf 'yes\n\n\nyes\n' | terminal --wizard)
check "model check runs as the first user after the host check" test "$(cat "$TEST_CALLS")" = $'doctor\nmodel alice'
check "working model access completes setup" \
  bash -c 'grep -q "model access: the model answered" <<<"$1" && grep -q "Host setup is complete" <<<"$1"' _ "$out"
: >"$TEST_CALLS"
out=$(printf 'yes\n\n\nyes\n' | TEST_MODEL_FAIL=yes terminal --wizard 2>&1) && rc=0 || rc=$?
check "refused model access fails setup" test "$rc" -ne 0
check "refused model access is reported apart from the host configuration" \
  bash -c 'grep -q "host configuration: passed" <<<"$1" && grep -q "model access: the model did not answer" <<<"$1"' _ "$out"
check "refused model access does not report completion" bash -c '! grep -q "Host setup is complete" <<<"$1"' _ "$out"

: >"$TEST_CALLS"
out=$(printf 'yes\n\nalice bad.name\n' | terminal --wizard 2>&1) && rc=0 || rc=$?
check "invalid names stop setup before any user is added" test "$rc" -ne 0
check "invalid names cause no operator calls" test ! -s "$TEST_CALLS"
out=$(printf 'yes\n\nadmin\n' | terminal --wizard 2>&1) && rc=0 || rc=$?
check "privileged accounts cannot be users in the wizard" test "$rc" -ne 0
check "privileged accounts cause no operator calls" test ! -s "$TEST_CALLS"
out=$(printf 'yes\nyes\n\nno\n' | terminal --wizard)
check "setup can turn on auto-enroll" test "$(cat "$TEST_CALLS")" = $'auto-enroll on\ndoctor'
: >"$TEST_CALLS"

out=$(printf 'yes\n\n\n' | TEST_DOCTOR_FAIL=yes terminal --wizard 2>&1) && rc=0 || rc=$?
check "a failed host check fails setup" test "$rc" -ne 0
check "a failed host check does not report completion" bash -c '! grep -q "Host setup is complete" <<<"$1"' _ "$out"

export HOME="$tmp/home" TEST_UID=1001
mkdir -p "$HOME/.config/onbehalf"
printf 'test-personal-key' >"$HOME/.config/onbehalf/gateway.key"
before=$(sha256sum "$HOME/.config/onbehalf/gateway.key")
out=$(bash "$self" --login </dev/null)
check "non-terminal login is silent" test -z "$out"
check "non-terminal login does not mark the welcome as seen" test ! -e "$HOME/.config/onbehalf/welcome-seen"
out=$(terminal --login </dev/null)
check "first user login shows how to start OpenCode" grep -q 'Start the AI harness: opencode' <<<"$out"
check "user login needs no wizard or tool authentication" bash -c '! grep -Eq "Start host setup|az login|gh auth login" <<<"$1"' _ "$out"
check "user login keeps the personal key" test "$(sha256sum "$HOME/.config/onbehalf/gateway.key")" = "$before"
check "welcome state is private" test "$(stat -c %a "$HOME/.config/onbehalf/welcome-seen")" = 600
check "the last login is private" test "$(stat -c %a "$HOME/.config/onbehalf/last-login")" = 600

# Every later login: a short message with what matters now.
: >"$TEST_CALLS"
out=$(terminal --login </dev/null)
check "later logins show how to start the AI harness and get help" \
  bash -c 'grep -q "start the AI harness: opencode" <<<"$1" && grep -q "Problems: onbehalf status" <<<"$1"' _ "$out"
check "later logins do not repeat the welcome" bash -c '! grep -q "Model access is ready" <<<"$1"' _ "$out"
check "later logins say nothing about finished work tools or an unchanged stack" \
  bash -c '! grep -Eq "Work tools to finish|stack changed" <<<"$1"' _ "$out"
check "later logins refresh the work tool states in the background" grep -qx refresh "$TEST_CALLS"
out=$(TEST_OFFER=yes terminal --login </dev/null)
check "a login that ran the work tool wizard does not repeat its summary" bash -c '! grep -q "start the AI harness" <<<"$1"' _ "$out"
printf 'git\tok\ngh\ttodo\naz\twarn\nmcp:x\tmissing\n' >"$HOME/.config/onbehalf/tools-state"
out=$(terminal --login </dev/null)
check "later logins name the work tools to finish, not those missing on the host" \
  bash -c 'grep -q "Work tools to finish: onbehalf tools gh az" <<<"$1" && ! grep -q "mcp:x" <<<"$1"' _ "$out"
rm "$HOME/.config/onbehalf/tools-state"
rm -rf "$TEST_STACK/current"
mkdir -p "$TEST_STACK/releases/a" "$TEST_STACK/releases/b"
ln -s releases/a "$TEST_STACK/current"
out=$(terminal --login </dev/null)
check "the first noted stack release is not a change" bash -c '! grep -q "stack changed" <<<"$1"' _ "$out"
ln -sfn releases/b "$TEST_STACK/current"
out=$(terminal --login </dev/null)
check "a login after a stack update says so" grep -q 'shared stack changed after your last login' <<<"$out"
out=$(terminal --login </dev/null)
check "the stack update is told once" bash -c '! grep -q "stack changed" <<<"$1"' _ "$out"

rm "$HOME/.config/onbehalf/gateway.key"
out=$(terminal --login </dev/null)
check "without auto-enroll, a user without a key asks the operator" grep -q 'Ask the operator to add your account' <<<"$out"
echo ONBEHALF_AUTO_ENROLL=yes >"$ONBEHALF_ETC/enroll.conf"
out=$(terminal --login </dev/null)
check "with auto-enroll, a user without a key is told why and what to do" \
  bash -c 'grep -q "did not set up your account at this login" <<<"$1" && grep -q "sudo onbehalf user enroll" <<<"$1"' _ "$out"
rm "$ONBEHALF_ETC/enroll.conf"

: >"$TEST_CALLS"
bash "$self" --profile </dev/null
check "the profile ignores non-interactive shells" test ! -s "$TEST_CALLS"
timeout 15 script -qefc "bash --noprofile --norc -i '$self' --profile" /dev/null </dev/null >/dev/null
check "the profile calls login in an interactive terminal" test "$(cat "$TEST_CALLS")" = login

export ONBEHALF_ETC="$tmp/missing"
out=$(terminal --login </dev/null)
check "an incomplete host directs non-root users to an administrator" grep -q 'administrator must run: sudo onbehalf setup' <<<"$out"
out=$(printf 'no\n' | TEST_UID=0 terminal --login)
check "an incomplete host offers setup to root" grep -q 'Start host setup' <<<"$out"

# In the host suite, also check the installed CLI against the real gateway.
if [ "$src" = /src ]; then
  unset ONBEHALF_ETC
  export HOME="$original_home"
  admin_before=$(sha256sum /etc/onbehalf/gateway-admin.key)
  alice_before=$(sha256sum /home/alice/.config/onbehalf/gateway.key)
  stack_before=$(readlink /opt/onbehalf/stack/current)
  out=$(printf 'yes\n\n\nno\n' | timeout 30 script -qefc 'onbehalf setup' /dev/null)
  check "installed setup verifies the real host" grep -q 'Host setup is complete' <<<"$out"
  out=$(printf 'yes\n\n\nyes\n' | timeout 90 script -qefc 'onbehalf setup' /dev/null)
  check "installed setup gets an answer from the model" grep -q 'model access: the model answered' <<<"$out"
  check "installed repeat setup keeps the gateway key" test "$(sha256sum /etc/onbehalf/gateway-admin.key)" = "$admin_before"
  check "installed repeat setup keeps the shared release" test "$(readlink /opt/onbehalf/stack/current)" = "$stack_before"
  out=$(runuser -l alice -c 'onbehalf login' </dev/null)
  check "installed login is silent without a terminal" test -z "$out"
  out=$(timeout 15 script -qefc "runuser -l alice -c 'onbehalf login'" /dev/null </dev/null)
  check "installed first user login shows OpenCode" grep -q 'Start the AI harness: opencode' <<<"$out"
  check "installed user login keeps the personal key" test "$(sha256sum /home/alice/.config/onbehalf/gateway.key)" = "$alice_before"
  out=$(timeout 15 script -qefc "runuser -l alice -c 'onbehalf login'" /dev/null </dev/null)
  check "installed later user login shows the short message" grep -q 'start the AI harness: opencode' <<<"$out"
fi
