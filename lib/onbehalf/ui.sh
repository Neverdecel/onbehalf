# shellcheck shell=bash
# Output and prompt helpers. Colour only on a terminal, and never with NO_COLOR.

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _b=$'\e[1m' _d=$'\e[2m' _g=$'\e[32m' _y=$'\e[33m' _r=$'\e[31m' _c=$'\e[36m' _0=$'\e[0m'
else
  _b="" _d="" _g="" _y="" _r="" _c="" _0=""
fi

UI_ERRORS=0
UI_WARNINGS=0

heading() { printf '\n%s%s%s\n' "$_b" "$*" "$_0"; }
ok() { printf '  %s✓%s %s\n' "$_g" "$_0" "$*"; }
warn() {
  printf '  %s!%s %s\n' "$_y" "$_0" "$*"
  UI_WARNINGS=$((UI_WARNINGS + 1))
}
err() {
  printf '  %s✗%s %s\n' "$_r" "$_0" "$*"
  UI_ERRORS=$((UI_ERRORS + 1))
}
info() { printf '  %s·%s %s\n' "$_d" "$_0" "$*"; }
# The fix for the last warning or error, as a command or a short instruction.
fix() { printf '      %sfix:%s %s\n' "$_d" "$_0" "$*"; }

summary() {
  printf '\n'
  if [ "$UI_ERRORS" -gt 0 ]; then
    printf '%s%d error(s)%s, %d warning(s)\n' "$_r" "$UI_ERRORS" "$_0" "$UI_WARNINGS"
  elif [ "$UI_WARNINGS" -gt 0 ]; then
    printf '%sno errors%s, %d warning(s)\n' "$_g" "$_0" "$UI_WARNINGS"
  else
    printf '%sall good%s\n' "$_g" "$_0"
  fi
}

# result ok|fail|skip "Text": one line of a final result. Does not count:
# the checks above it already did.
result() {
  case $1 in
    ok) printf '  %s✓%s %s\n' "$_g" "$_0" "$2" ;;
    fail) printf '  %s✗%s %s\n' "$_r" "$_0" "$2" ;;
    *) printf '  %s·%s %s\n' "$_d" "$_0" "$2" ;;
  esac
}

# ask VAR "Question" [default]: read a value from the terminal.
ask() {
  read -r -p "  $2${3:+ [$3]}: " "$1" </dev/tty
  [ -n "${!1}" ] || printf -v "$1" '%s' "${3:-}"
}

# ask_secret VAR "Question": read a value without showing it.
ask_secret() {
  read -r -s -p "  $2 (input hidden): " "$1" </dev/tty
  printf '\n' >/dev/tty
}
