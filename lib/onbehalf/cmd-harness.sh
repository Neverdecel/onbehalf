# shellcheck shell=bash
# onbehalf harness NAME: change the AI harness of the host. Each user gets
# the links of the new AI harness. The personal settings and the private
# state of the old AI harness stay in the account of the user.

cmd_harness() {
  need_root
  load_conf
  local new=${1:-} old label path missing models="" u home
  { [ $# -eq 1 ] && harness_known "$new"; } || die "usage: onbehalf harness NAME. NAME is one of: ${HARNESSES[*]}"
  old=$(harness_id)
  label=$("harness_${new}_label")
  if [ "$new" = "$old" ]; then
    info "$label is the AI harness of this host"
    return
  fi

  # Do each check before the first change.
  heading "Change the AI harness from $(harness label) to $label"
  path=$(command -v "$("harness_${new}_command")") || path=
  case $path in
    "" | /home/* | /root/*) die "$label is not installed for the full host. Install $label, then run this command again" ;;
  esac
  ok "$label is installed for the full host"
  if [ -e "$ONBEHALF_STACK/current" ]; then
    [ -d "$ONBEHALF_STACK/current/$new" ] \
      || die "the shared stack has no configuration for $label. Install a stack source with models.json, then run this command again"
    models=$(stack_models "$ONBEHALF_STACK/current")
  fi
  missing=$(ONBEHALF_HARNESS=$new gateway_api_missing)
  [ -z "$missing" ] || die "the gateway does not serve the API of $label: ${missing//$'\n'/ }. The AI harness did not change"
  ok "the gateway serves the API of $label"

  # The gateway keys get the routes of the new AI harness first. If the
  # gateway fails, the host keeps its AI harness. Run the command again.
  if [ -n "$models" ]; then
    for u in $(people); do ONBEHALF_HARNESS=$new gateway_models_update "$u" "$models"; done
    ok "the gateway keys permit the API of $label"
  fi

  for u in $(people); do
    harness stop "$u"
    harness user_unlink "$(home_of "$u")"
    harness user_remove "$u"
  done
  harness deactivate

  if grep -q '^ONBEHALF_HARNESS=' "$ONBEHALF_ETC/onbehalf.conf"; then
    sed -i "s/^ONBEHALF_HARNESS=.*/ONBEHALF_HARNESS=$new/" "$ONBEHALF_ETC/onbehalf.conf"
  else
    echo "ONBEHALF_HARNESS=$new" >>"$ONBEHALF_ETC/onbehalf.conf"
  fi
  ONBEHALF_HARNESS=$new
  ok "saved the AI harness in $ONBEHALF_ETC/onbehalf.conf"

  [ -z "$models" ] || harness activate
  for u in $(people); do
    home=$(home_of "$u")
    harness user_add "$u" "$home" "$(id -gn "$u")" no
  done
  info "Each user starts the AI harness with: $(harness command)"
}
