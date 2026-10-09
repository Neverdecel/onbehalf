#!/usr/bin/env bash
# Work tools: `onbehalf tools` and the offer at the first login. A user sets
# up Git, the GitHub CLI, the Azure CLI and the MCP servers of the shared stack
# with each native login, as themselves. Fake gh and az ask which account to
# "log in" as; a fake MCP server has a real OAuth login, done by OpenCode.
#
# Each run gets a terminal from `script`, as its controlling terminal like an
# SSH login: runuser --session-command, because runuser -c starts a new
# session without one. Plain runs (ONBEHALF_PLAIN=1) take numbered answers;
# one run uses the arrow-key menus.
set -uo pipefail
. /src/test/lib.sh

T=$(mktemp -d)
chmod 0755 "$T"
E=/tmp/fake-entra
MAP=/etc/onbehalf/entra.map
UPN=tina.test@corp.test

# run USER COMMAND INPUT: run COMMAND as USER in a login shell on a terminal,
# with the lines of INPUT typed in. Prints what the terminal showed.
run() {
  printf '%b' "$3" | timeout 120 script -qec "runuser -l $1 --session-command '$2'" /dev/null 2>&1 | plain
}
# The terminal output without carriage returns and colours.
plain() { tr -d '\r' | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g'; }

# A run to talk with: start USER COMMAND, then await PATTERN and send TEXT.
start() {
  rm -f "$T/in" "$T/out"
  mkfifo "$T/in"
  # runuser --session-command of util-linux 2.42 (Arch) starts the command with
  # SIGINT ignored, so Ctrl-C would do nothing. An SSH login does not.
  (timeout 180 script -qefc "runuser -l $1 --session-command 'env --default-signal=INT $2'" /dev/null <"$T/in" >"$T/out" 2>&1) &
  RUN_PID=$!
  exec 7>"$T/in"
}
send() { printf '%b' "$1" >&7; }
await() {
  local i
  for ((i = 0; i < ${2:-60} * 10; i++)); do
    plain <"$T/out" | grep -qE "$1" && return 0
    sleep 0.1
  done
  echo "    (did not see: $1)"
  return 1
}
finish() {
  exec 7>&-
  wait "$RUN_PID"
  plain <"$T/out"
}

git_of() { as "$1" "git config --global user.$2"; }
has() { grep -q -- "$1" <<<"$2"; }
# line PATTERN TEXT: the number of the first line of TEXT that matches.
line() { grep -n -m1 -- "$1" <<<"$2" | cut -d: -f1; }

# Host: fake gh and az, and a user tina linked to her Entra account.
install -d -m 0777 "$E"
install -m 0755 /src/test/fixtures/fake-az.sh /usr/local/bin/az
install -m 0755 /src/test/fixtures/fake-gh.sh /usr/local/bin/gh
useradd -m -s /bin/bash -c "Tina Test" tina
onbehalf user add tina >/dev/null 2>&1
echo "tina 6a1f0000-0000-4000-8000-00000000c0de $UPN" >>"$MAP"
chmod 0644 "$MAP"

# No prompts without a terminal: SSH commands and file transfers.
out=$(as tina "onbehalf login" 2>&1)
check "a login without a terminal prints nothing" test -z "$out"
check "a login without a terminal does not use up the offer" test ! -e /home/tina/.config/onbehalf/tools-offered
out=$(as tina "onbehalf tools" 2>&1)
check "onbehalf tools without a terminal stops and says why" has "must have a terminal" "$out"
out=$(timeout 30 script -qec "runuser -l tina -c 'onbehalf tools'" /dev/null </dev/null 2>&1)
check "a terminal that is not the controlling one counts as none" has "must have a terminal" "$out"

# Who may run it.
out=$(onbehalf tools 2>&1)
check "root cannot run the wizard" has "not as root" "$out"
out=$(run tina "env HOME=/home/alice onbehalf tools" "")
check "a HOME of another account is refused" has "HOME is /home/alice, but the home directory of tina is /home/tina" "$out"
check "nothing is written into that other home" test ! -e /home/alice/.fake-gh-user

# First login: the welcome, then the offer, with every open tool selected.
out=$(run tina "ONBEHALF_PLAIN=1 onbehalf login" '\n\n\ntina-gh\n'"$UPN"'\n')
sed 's/^/        /' <<<"$out"
check "the first login offers the work tools" has "Work tools  ·  first login" "$out"
check "the offer lists the open tools, all selected" has "Numbers to set up, 0 for none \[1 2 3\]" "$out"
check "the Git name defaults to the full name of the account" has "Name \[Tina Test\]" "$out"
check "the Git email defaults to the Entra account" has "Email \[$UPN\]" "$out"
check "Git is set up as tina" test "$(git_of tina name) <$(git_of tina email)>" = "Tina Test <$UPN>"
check "gh is logged in through its own login" test "$(cat /home/tina/.fake-gh-user)" = tina-gh
check "az is logged in through its own login" test "$(cat /home/tina/.fake-az-user)" = "$UPN"
check "the Azure login is checked against the Entra account" has "This is your Entra account" "$out"
check "the summary says every tool is ready" has "Your work tools are ready" "$out"
check "the summary shows the verified GitHub login" has "logged in as tina-gh (set now)" "$out"
check "the offer is marked as made" test -e /home/tina/.config/onbehalf/tools-offered
out=$(run tina "ONBEHALF_PLAIN=1 onbehalf login" "")
check "a later login does not offer again" bash -c '! grep -q "Work tools" <<<"$1"' _ "$out"

# Running it again: done tools are not selected, so Enter changes nothing.
before=$(sha256sum /home/tina/.gitconfig /home/tina/.fake-gh-user /home/tina/.fake-az-user)
out=$(run tina "ONBEHALF_PLAIN=1 onbehalf tools" '\n')
check "done tools are shown with their setup" has "✓ Tina Test <$UPN>" "$out"
check "nothing is selected when everything is done" has "0 for none \[0\]" "$out"
check "Enter keeps every setting and login" test "$(sha256sum /home/tina/.gitconfig /home/tina/.fake-gh-user /home/tina/.fake-az-user)" = "$before"
check "the wizard says nothing changed" has "Nothing changed" "$out"

# A change needs an explicit choice; the current value is the default.
out=$(run tina "ONBEHALF_PLAIN=1 onbehalf tools git" 'Tina T. Test\n\n')
check "an explicit change of Git starts from the current name" has "Name \[Tina Test\]" "$out"
check "the new name is set, the email kept" test "$(git_of tina name) <$(git_of tina email)>" = "Tina T. Test <$UPN>"
out=$(run tina "ONBEHALF_PLAIN=1 onbehalf tools git" '\nnot-an-address\nt@corp.test\n')
check "a wrong email address is asked again" has "that is not an email address" "$out"
check "the corrected email is set" test "$(git_of tina email)" = t@corp.test

# The Azure CLI logged in as another account: a choice, not a silent fix.
as tina "echo other@personal.test > ~/.fake-az-user"
out=$(run tina "ONBEHALF_PLAIN=1 onbehalf tools" '\n2\n')
check "a wrong Azure account is shown in the menu" has "other@personal.test (not your Entra account)" "$out"
check "a wrong Azure account is preselected" has "0 for none \[3\]" "$out"
check "keeping the other account keeps it" test "$(cat /home/tina/.fake-az-user)" = other@personal.test
check "the summary says it was kept" has "other@personal.test, not as your Entra account $UPN (kept)" "$out"
out=$(run tina "ONBEHALF_PLAIN=1 onbehalf tools az" '1\n'"$UPN"'\n')
check "the user can log out and log in as the Entra account" test "$(cat /home/tina/.fake-az-user)" = "$UPN"

# Cancel and failure: the step stops, the others go on, the summary says so.
as tina "rm ~/.fake-gh-user ~/.fake-az-user"
start tina "ONBEHALF_PLAIN=1 onbehalf tools gh az"
await "fake gh: account to log in as" && send '\003'
await "fake az: account to log in as" && send "$UPN\n"
await "Start the AI harness"
out=$(finish)
check "Ctrl-C cancels only the GitHub login" has "GitHub CLI: cancelled" "$out"
check "the Azure step still runs after a cancel" test "$(cat /home/tina/.fake-az-user)" = "$UPN"
check "the summary marks the cancelled tool" has "✗ GitHub CLI *cancelled" "$out"
check "the summary says how to finish it" has "Finish later: onbehalf tools gh" "$out"
out=$(run tina "onbehalf login" "")
check "a later login names the work tool to finish" has "Work tools to finish: onbehalf tools gh" "$out"
out=$(run tina "ONBEHALF_PLAIN=1 onbehalf tools gh" 'cancel\n')
check "a failed login says it did not finish" has "did not finish: not logged in" "$out"
out=$(run tina "ONBEHALF_PLAIN=1 onbehalf tools gh" 'tina-gh\n')
check "the retry command finishes the login" test "$(cat /home/tina/.fake-gh-user)" = tina-gh
out=$(run tina "onbehalf login" "")
check "a later login then names nothing to finish" bash -c '! grep -q "Work tools to finish" <<<"$1"' _ "$out"

# A day-old state is read again in the background, for the next login.
state=/home/tina/.config/onbehalf/tools-state
as tina "sed -i 's/^gh\tok$/gh\ttodo/' $state && touch -d '2 days ago' $state"
out=$(run tina "onbehalf login" "")
check "a login shows the last saved state at once" has "Work tools to finish: onbehalf tools gh" "$out"
for _ in $(seq 60); do
  [ -z "$(find "$state" -mmin -1440)" ] || break
  sleep 1
done
check "the login read the states again in the background" grep -qP '^gh\tok$' "$state"
check "the saved states are private" test "$(stat -c %a "$state")" = 600

# A tool that is not installed: shown, cannot be selected, does not block.
mv /usr/local/bin/gh "$T/gh"
as tina "git config --global --unset user.name"
out=$(run tina "ONBEHALF_PLAIN=1 onbehalf tools" '2\n1\n\n\n')
check "a missing tool says to ask the operator" has "GitHub CLI *not installed · ask your operator" "$out"
check "a missing tool cannot be selected" has "select from the numbers above" "$out"
check "the other tools still run" test "$(git_of tina name)" = "Tina Test"
check "the summary lists the missing tool" has "! GitHub CLI *not installed · ask your operator" "$out"
out=$(as tina "onbehalf status" 2>&1)
check "status shows the missing tool" has "GitHub CLI: not installed on this host" "$out"
mv "$T/gh" /usr/local/bin/gh

# Status points to the wizard for each open tool.
as tina "rm ~/.fake-az-user"
out=$(as tina "onbehalf status" 2>&1)
check "status shows the verified work tools" has "GitHub CLI: logged in as tina-gh" "$out"
check "status gives the wizard as the fix" has "fix: onbehalf tools az" "$out"

# The arrow-key menus: Esc skips, space and enter select and confirm.
out=$(run tina "TERM=xterm onbehalf tools" '\033')
check "the menus show the key help" has "↑↓ move   space select   enter confirm   esc skip" "$out"
check "Esc changes nothing" has "Nothing changed" "$out"
out=$(run tina "TERM=xterm onbehalf tools" ' \033[B\033[B\033[B\r\r\r')
check "space selects Git and enter on Continue runs it" has "Git: Tina Test <t@corp.test>" "$out"

# MCP servers of the shared stack: the same menu, OpenCode's own login.
node /src/test/fixtures/fake-mcp.js &
mcp_pid=$!
cp -a /src/test/stack "$T/stack"
jq '.mcp.servers = {
      tracker: {type: "remote", url: "http://127.0.0.1:7777/mcp"},
      static: {type: "remote", url: "http://127.0.0.1:7777/mcp", headers: {Authorization: "Bearer {env:NONE}"}},
      off: {type: "remote", url: "http://127.0.0.1:7777/mcp", enabled: false}}' \
  /src/test/stack/opencode/opencode.json >"$T/stack/opencode/opencode.json"
onbehalf stack install "$T/stack" >/dev/null 2>&1
check "a shared stack with MCP servers installs" test $? -eq 0
out=$(run tina "ONBEHALF_PLAIN=1 onbehalf tools" '\n')
check "the shared MCP server with a login is in the menu" has "tracker *not logged in" "$out"
check "the menu shows the work tools in a group" \
  test "$(line '^ *Work tools$' "$out")" = $(($(line '1) .* Git ' "$out") - 1))
check "the MCP connections follow in their own group" \
  test "$(line '^ *MCP connections$' "$out")" = $(($(line '4) .* tracker ' "$out") - 1))
check "an empty line is between the groups" \
  test "$(line '^ *MCP connections$' "$out")" = $(($(line '3) .* Azure CLI ' "$out") + 2))
check "MCP servers without a personal login are not" bash -c '! grep -Eq "\) .*(static|off) " <<<"$1"' _ "$out"
start tina "ONBEHALF_PLAIN=1 onbehalf tools mcp:tracker"
await "Open this address in your browser" 90
url=$(plain <"$T/out" | grep -oE 'http://127\.0\.0\.1:7777/authorize[^[:space:]]+' | head -1)
callback=$(curl -s -o /dev/null -w '%{redirect_url}' "$url")
check "the login goes to a callback on this host" grep -qE '^http://(127\.0\.0\.1|localhost):[0-9]+/' <<<"$callback"
await "Address:" && send "$callback\n"
await "Start the AI harness" 90
out=$(finish)
sed 's/^/        /' <<<"$out" | tail -8
check "the pasted address finishes OpenCode's login" has "✓ tracker (MCP): connected" "$out"
check "the summary names both groups" has "work tools and MCP connections" "$out"
out=$(as tina "cd ~ && NO_COLOR=1 opencode mcp list" 2>&1)
check "tina's OpenCode is connected to the MCP server" grep -Eq "tracker +connected" <<<"$out"
out=$(as bob "cd ~ && NO_COLOR=1 opencode mcp list" 2>&1)
check "the login of tina is not the login of bob" bash -c '! grep -Eq "tracker +connected" <<<"$1"' _ "$out"
kill "$mcp_pid" 2>/dev/null
onbehalf stack install /src/test/stack >/dev/null 2>&1

# Work tools of the shared stack: the operator adds tools/ID.json, no change
# to onbehalf. A file that is not correct stops the install.
install -m 0755 /src/test/fixtures/fake-vault.sh /usr/local/bin/vault
rm -rf "$T/stack"
cp -a /src/test/stack "$T/stack"
mkdir "$T/stack/tools"
vault='{"label": "Vault", "help": "Your own Vault login, for the secrets of the team.",
  "command": "vault", "check": ["vault", "token", "lookup"],
  "login": ["vault", "login", "-method=oidc"], "whoami": ["vault", "print", "token"]}'
# refused FILE CONTENT: stack install refuses tools/FILE; the stack stays.
refused() {
  local before out
  rm -f "$T/stack/tools/"*
  printf '%s' "$2" >"$T/stack/tools/$1"
  before=$(readlink /opt/onbehalf/stack/current)
  out=$(onbehalf stack install "$T/stack" 2>&1) && return 1
  has "tools/$1" "$out" && test "$(readlink /opt/onbehalf/stack/current)" = "$before"
}
check "a stack tool cannot replace a built-in tool" refused gh.json "$vault"
check "a stack tool must be valid JSON" refused vault.json '{"label": '
check "a stack tool with an unknown key is refused" refused vault.json "$(jq '.logn = .login' <<<"$vault")"
check "a stack tool command is a list, not shell code" refused vault.json "$(jq '.check = "vault token lookup"' <<<"$vault")"
rm -f "$T/stack/tools/"*
printf '%s' "$vault" >"$T/stack/tools/vault.json"
onbehalf stack install "$T/stack" >/dev/null 2>&1
check "a shared stack with a work tool installs" test $? -eq 0
run tina "onbehalf login" "" >/dev/null
for _ in $(seq 60); do
  ! grep -qP '^vault\t' "$state" || break
  sleep 1
done
check "the login after a stack install reads the states again" grep -qP '^vault\ttodo$' "$state"
out=$(as tina "onbehalf status" 2>&1)
check "status shows the stack tool" has "Vault: not logged in" "$out"
check "status gives the wizard as the fix of the stack tool" has "fix: onbehalf tools vault" "$out"
out=$(run tina "ONBEHALF_PLAIN=1 onbehalf tools vault" 'tina-vault\n')
check "the stack tool runs its native login" test "$(cat /home/tina/.fake-vault-user)" = tina-vault
check "the summary shows the account of the stack tool" has "Vault: logged in as tina-vault" "$out"
out=$(run tina "ONBEHALF_PLAIN=1 onbehalf tools" '\n')
check "the menu shows the stack tool with its account" has "✓ tina-vault" "$out"
mv /usr/local/bin/vault "$T/vault"
out=$(as tina "onbehalf tools --list")
check "a stack tool that is not installed is missing" grep -qP '^vault\tmissing$' <<<"$out"
rm -f "$T/vault"
onbehalf stack install /src/test/stack >/dev/null 2>&1

# An operator's runtime account: the wizard runs there, as the runtime account.
useradd -m -s /bin/bash -c "Oscar Op" oscar
# --agent is the old name of --runtime. It must still work.
onbehalf operator add --agent oscar >/dev/null 2>&1
mv /usr/local/bin/gh "$T/gh"
out=$(printf '1\nOscar Op\noscar@corp.test\nexit\n' | timeout 120 script -qec "env TERM=dumb onbehalf operator shell oscar" /dev/null 2>&1 | plain)
mv "$T/gh" /usr/local/bin/gh
check "the runtime account is offered the work tools" has "Work tools  ·  first login" "$out"
check "the start message names the runtime account" has "This is the runtime account of oscar" "$out"
check "a missing tool tells the operator to install it" has "install it on this host (you are its operator)" "$out"
check "Git is set in the runtime account" test "$(git_of oscar-agent email)" = oscar@corp.test
check "the operator account is not changed" test ! -e /home/oscar/.gitconfig
out=$(run oscar "ONBEHALF_PLAIN=1 onbehalf tools" "")
check "an operator's own account is refused" has "Open your runtime account: sudo onbehalf operator shell" "$out"

# Cleanup.
onbehalf user remove oscar-agent >/dev/null 2>&1
onbehalf operator remove oscar >/dev/null 2>&1
userdel -r oscar 2>/dev/null
onbehalf user remove tina >/dev/null 2>&1
sed -i '/^tina /d' "$MAP"
rm -rf "$T" "$E" /usr/local/bin/az /usr/local/bin/gh
check "work tool test accounts are removed (test cleanup)" bash -c '! id tina && ! id oscar && ! id oscar-agent' 2>/dev/null

exit $FAILED
