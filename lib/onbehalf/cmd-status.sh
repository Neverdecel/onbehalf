# shellcheck shell=bash
# onbehalf status: a user checks their own setup. Runs without root.
# With --model-check, also send one short model request with the own key.

cmd_status() {
  load_conf
  [ "$(id -u)" != 0 ] || die "run this as yourself, not as root"
  local check_model=no model="" u key
  while [ $# -gt 0 ]; do
    case $1 in
      --model-check)
        check_model=yes
        shift
        ;;
      --model)
        [ -n "${2:-}" ] || die "give a value for --model"
        model=$2
        check_model=yes
        shift 2
        ;;
      *) die "usage: onbehalf status [--model-check] [--model MODEL]" ;;
    esac
  done
  u=$(id -un)
  key="$HOME/.config/onbehalf/gateway.key"

  heading "onbehalf for $u"
  if [ -e "$ONBEHALF_STACK/current" ]; then
    ok "shared stack $(basename "$(readlink "$ONBEHALF_STACK/current")")"
  else
    err "this host has no shared stack yet"
    fix "ask your operator"
  fi

  if [ ! -r "$key" ]; then
    err "you have no gateway key"
    fix "ask your operator to run: sudo onbehalf user add $u"
  elif gateway_call "$key" GET /v1/models >/dev/null 2>&1; then
    ok "your gateway key works"
  else
    err "the gateway does not accept your key"
    fix "ask your operator to run: sudo onbehalf user add $u"
  fi
  harness_opencode_check "$u" "$HOME"

  heading "Model access"
  if [ "$check_model" = no ]; then
    info "not checked. To send one short test request: onbehalf status --model-check"
  elif [ ! -r "$key" ]; then
    err "no gateway key to send the request with"
  elif [ -z "$model" ] && ! model=$(stack_default_model "$ONBEHALF_STACK/current/opencode/opencode.json" 2>/dev/null); then
    err "the shared stack has no model to check"
    fix "ask your operator"
  elif ! model_access_check "$key" "$model" "$u"; then
    fix "send this output to your operator"
  fi

  heading "Your model use"
  if [ -r "$key" ]; then status_usage "$key" "$u"; else info "no gateway key"; fi

  heading "Your work tools (each keeps its own login, private to you)"
  status_entra "$u"
  tools_status

  summary
  [ "$UI_ERRORS" = 0 ] || exit 1
}

# The own model use of the last 7 and 30 days, read with the own key. The
# gateway gives a personal key only the use of that key's owner.
status_usage() {
  local out
  if ! out=$(gateway_call "$1" GET "/user/daily/activity?start_date=$(date -u -d '-29 days' +%F)&end_date=$(date -u -d '+1 day' +%F)&page_size=100" 2>/dev/null); then
    info "not available: your gateway key cannot read your model use yet"
    fix "ask your operator to run: sudo onbehalf stack install --no-restart <stack source>"
    return 0
  fi
  jq -r --arg d7 "$(date -u -d '-6 days' +%F)" "$REPORT_FMT"'
    def total(f): map(.metrics | f // 0) | add // 0;
    def line($label): "\($label): \(total(.api_requests)) requests, \(total(.failed_requests)) failed, \(total(.total_tokens) | tok) tokens, spend \(total(.spend) | if . == 0 then "$0" else usd end)";
    (.results // []) as $r
    | ($r | map(select(.date >= $d7)) | line("last 7 days")), ($r | line("last 30 days"))' <<<"$out" \
    | while IFS= read -r line; do info "$line"; done
  info "only you and the operators of this host can see your model use"
}

# For a user linked to Entra: the account the Azure CLI must use.
status_entra() {
  local upn
  upn=$(entra_upn_of "$1")
  [ -z "$upn" ] || ok "Entra account: $upn"
}
