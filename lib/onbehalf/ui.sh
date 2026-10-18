# shellcheck shell=bash
# Output and prompt helpers. Colour only on a terminal, and never with NO_COLOR.

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _b=$'\e[1m' _d=$'\e[2m' _g=$'\e[32m' _y=$'\e[33m' _r=$'\e[31m' _c=$'\e[36m' _0=$'\e[0m'
else
  _b="" _d="" _g="" _y="" _r="" _c="" _0=""
fi

UI_ERRORS=0
UI_WARNINGS=0
# When UI_RECORD names a file, the helpers below add one "kind<TAB>text" line
# to it and print nothing. ui_json makes JSON from the file.
UI_RECORD=""

ui_record() {
  local text=${*:2}
  printf '%s\t%s\n' "$1" "${text//$'\t'/ }" >>"$UI_RECORD"
}

heading() {
  if [ -n "$UI_RECORD" ]; then ui_record heading "$*"; else printf '\n%s%s%s\n' "$_b" "$*" "$_0"; fi
}
ok() {
  if [ -n "$UI_RECORD" ]; then ui_record ok "$*"; else printf '  %s✓%s %s\n' "$_g" "$_0" "$*"; fi
}
warn() {
  if [ -n "$UI_RECORD" ]; then ui_record warning "$*"; else printf '  %s!%s %s\n' "$_y" "$_0" "$*"; fi
  UI_WARNINGS=$((UI_WARNINGS + 1))
}
err() {
  if [ -n "$UI_RECORD" ]; then ui_record error "$*"; else printf '  %s✗%s %s\n' "$_r" "$_0" "$*"; fi
  UI_ERRORS=$((UI_ERRORS + 1))
}
info() {
  if [ -n "$UI_RECORD" ]; then ui_record info "$*"; else printf '  %s·%s %s\n' "$_d" "$_0" "$*"; fi
}
# The fix for the last warning or error, as a command or a short instruction.
fix() {
  if [ -n "$UI_RECORD" ]; then ui_record fix "$*"; else printf '      %sfix:%s %s\n' "$_d" "$_0" "$*"; fi
}

# ui_json FILE: the lines of a UI_RECORD file as a JSON array of checks:
# {"section", "result": ok|warning|error|info, "text", "fix"}. A fix line
# goes into the check above it.
ui_json() {
  jq -Rn '[inputs | split("\t") | {kind: .[0], text: (.[1:] | join(" "))}]
    | reduce .[] as $l ({section: null, checks: []};
        if $l.kind == "heading" then .section = $l.text
        elif $l.kind == "fix" then
          if (.checks | length) > 0 then .checks[-1].fix = $l.text else . end
        else .checks += [{section: .section, result: $l.kind, text: $l.text, fix: null}]
        end)
    | .checks' <"$1"
}

summary() {
  [ -z "$UI_RECORD" ] || return 0
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
