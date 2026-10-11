# shellcheck shell=bash
# onbehalf health: is onbehalf working right now? For the operator, as root.
# Short checks of the gateway, the shared stack, the disk, enrollments, the
# provider (from recent real requests) and the key of every user. With
# `health on`, a systemd timer runs `health --record` every few minutes. It
# keeps the last result, logs to the journal, and posts to a webhook only
# when the problems change: a new problem, or all checks pass again.
#
# The model probe is off by default: it sends a real model request on every
# run, with its own gateway key, so it never counts as a user's use.

HEALTH_CONF=${HEALTH_CONF:-$ONBEHALF_ETC/health.conf}
HEALTH_STATE=${HEALTH_STATE:-/var/lib/onbehalf/health.json}
HEALTH_PROBE_KEY=${HEALTH_PROBE_KEY:-$ONBEHALF_ETC/probe.key}
HEALTH_PROBE_USER=onbehalf-probe
# Recent real requests: this many minutes. A model fails when the provider
# failed at least this many of its requests, and at least half of them.
HEALTH_WINDOW_MIN=15
HEALTH_MIN_FAILURES=3
HEALTH_DISK_WARN=${HEALTH_DISK_WARN:-90}
HEALTH_DISK_FAIL=${HEALTH_DISK_FAIL:-97}

health_conf() {
  ONBEHALF_HEALTH=no ONBEHALF_HEALTH_EVERY=10 ONBEHALF_HEALTH_WEBHOOK='' ONBEHALF_HEALTH_FORMAT=slack ONBEHALF_HEALTH_PROBE=no
  # shellcheck source=/dev/null
  [ ! -r "$HEALTH_CONF" ] || . "$HEALTH_CONF"
}

# The webhook URL is a secret: whoever has it can post to the channel.
health_save() {
  (
    umask 077
    cat >"$HEALTH_CONF" <<EOF
# onbehalf health. Change it with: sudo onbehalf health on|off
ONBEHALF_HEALTH=$ONBEHALF_HEALTH
ONBEHALF_HEALTH_EVERY=$ONBEHALF_HEALTH_EVERY
ONBEHALF_HEALTH_WEBHOOK=$(printf %q "$ONBEHALF_HEALTH_WEBHOOK")
ONBEHALF_HEALTH_FORMAT=$ONBEHALF_HEALTH_FORMAT
ONBEHALF_HEALTH_PROBE=$ONBEHALF_HEALTH_PROBE
EOF
  )
  chmod 0600 "$HEALTH_CONF"
}

health_usage() {
  die "usage: onbehalf health [--json] | health on [--every MIN] [--webhook URL | --no-webhook] [--format slack|teams] [--probe | --no-probe] | health off | health alert-test"
}

cmd_health() {
  need_root
  load_conf
  health_conf
  case ${1:-} in
    on)
      shift
      health_enable "$@"
      ;;
    off)
      [ $# = 1 ] || health_usage
      health_disable
      ;;
    alert-test)
      [ $# = 1 ] || health_usage
      [ -n "$ONBEHALF_HEALTH_WEBHOOK" ] || die "no webhook is set. Run: sudo onbehalf health on --webhook URL"
      health_post "onbehalf on $(uname -n): test alert. Alerts arrive here when a health check starts or stops failing." '[]' \
        || die "the webhook did not accept the alert. Check the URL and the network of this host"
      ok "sent a test alert ($ONBEHALF_HEALTH_FORMAT format)"
      ;;
    *)
      local json=no record=no
      while [ $# -gt 0 ]; do
        case $1 in
          --json) json=yes ;;
          --record) record=yes ;;
          *) health_usage ;;
        esac
        shift
      done
      health_run "$json" "$record"
      ;;
  esac
}

# health_run JSON RECORD: run every check; exit 1 if one fails.
health_run() {
  local json=$1 record=$2 checks now result
  now=$(date -u '+%FT%TZ')
  checks=$(health_checks | jq -sc .)
  result=$(jq -nc --arg time "$now" --arg host "$(uname -n)" --argjson checks "$checks" '
    {time: $time, host: $host,
     status: (if any($checks[]; .status == "fail") then "fail"
              elif any($checks[]; .status == "warn") then "warn" else "ok" end),
     checks: $checks}')
  [ "$record" = no ] || health_record "$result"
  if [ "$json" = yes ]; then
    jq . <<<"$result"
  elif [ "$record" = no ]; then
    health_print "$result"
  fi
  [ "$(jq -r .status <<<"$result")" != fail ] || exit 1
}

# One JSON object per check: id, status (ok, warn, fail), text, fix.
health_result() { jq -nc --arg id "$1" --arg s "$2" --arg t "$3" --arg f "${4:-}" '{id: $id, status: $s, text: $t, fix: $f}'; }

health_checks() {
  local gw=yes
  if curl -fsS --max-time 10 "$ONBEHALF_GATEWAY_URL/health/liveliness" >/dev/null 2>&1; then
    health_result gateway ok "the gateway answers"
  else
    gw=no
    health_result gateway fail "the gateway $ONBEHALF_GATEWAY_URL does not answer" \
      "start the gateway; see the operator guide, section 'Model gateway'"
  fi
  if [ "$gw" = yes ]; then
    local missing
    missing=$(gateway_api_missing)
    if [ -z "$missing" ]; then
      health_result gateway-api ok "the gateway serves the API of $(harness label)"
    else
      health_result gateway-api fail "the gateway does not serve the API of $(harness label): ${missing//$'\n'/ }" \
        "use a LiteLLM version that serves these routes; see the operator guide, section 'Model gateway'"
    fi
    if gateway_admin GET /health/readiness 2>/dev/null | jq -e '.db == "connected"' >/dev/null; then
      health_result gateway-db ok "the gateway database is connected"
    else
      health_result gateway-db fail "the gateway database is not connected: no keys, no logs" \
        "check the database of the gateway"
    fi
    if gateway_admin GET "/key/list?size=1" >/dev/null 2>&1; then
      health_result admin-key ok "the gateway accepts the admin key"
    else
      health_result admin-key fail "the gateway does not accept the admin key" "sudo onbehalf init"
    fi
  fi

  if [ ! -e "$ONBEHALF_STACK/current" ]; then
    health_result stack fail "no shared stack" "sudo onbehalf stack install DIR"
  elif ! stack_models "$ONBEHALF_STACK/current" >/dev/null 2>&1; then
    health_result stack fail "the shared stack has no model catalog" "sudo onbehalf stack install DIR"
  elif [ -n "$(harness stack_problem)" ]; then
    health_result stack warn "the shared stack does not limit $(harness label) to its gateway providers" "sudo onbehalf doctor"
  else
    health_result stack ok "shared stack $(basename "$(readlink "$ONBEHALF_STACK/current")")"
  fi

  health_disk
  health_enrollments
  [ "$gw" = no ] || health_provider
  [ "$gw" = no ] || health_keys
  [ "$gw" = no ] || [ "$ONBEHALF_HEALTH_PROBE" != yes ] || health_probe
}

health_disk() {
  local used=0 where='' p u d
  for d in / "$ONBEHALF_STACK" /home /var/lib; do
    [ -e "$d" ] || continue
    read -r u p < <(df -P "$d" | awk 'NR == 2 { sub("%", "", $5); print $5, $6 }')
    [ "$u" -le "$used" ] || {
      used=$u
      where=$p
    }
  done
  if [ "$used" -ge "$HEALTH_DISK_FAIL" ]; then
    health_result disk fail "$where is $used% full" "remove files on $where"
  elif [ "$used" -ge "$HEALTH_DISK_WARN" ]; then
    health_result disk warn "$where is $used% full" "remove files on $where"
  else
    health_result disk ok "the disks are $used% full or less"
  fi
}

# Enrollments at login that failed in the last hour.
health_enrollments() {
  enroll_conf
  [ "$ONBEHALF_AUTO_ENROLL" = yes ] || return 0
  local since n
  since=$(date -d '-1 hour' -Is)
  n=$(awk -v s="$since" '$1 >= s && / could not (join|enroll in) onbehalf/ { n++ } END { print n + 0 }' "$ENROLL_LOG" 2>/dev/null) || n=0
  if [ "$n" = 0 ]; then
    health_result enroll ok "no failed enrollments in the last hour"
  else
    health_result enroll fail "$n enrollment(s) at login failed in the last hour" "see $ENROLL_LOG"
  fi
}

# Recent real requests that the provider refused or failed. Refusals by the
# gateway (a model outside the catalog, a revoked key) do not count.
health_provider() {
  local start end logs
  start=$(date -u -d "-$HEALTH_WINDOW_MIN minutes" '+%F %T')
  end=$(date -u -d '+1 minute' '+%F %T')
  logs=$(report_gateway_pages "/spend/logs/v2?start_date=$(report_urlenc "$start")&end_date=$(report_urlenc "$end")" data \
    '{model: (.model_group // .model), ok: (.status == "success"),
      provider: ((.metadata.error_information.llm_provider // "") != ""),
      code: (.metadata.error_information.normalized_error // .metadata.error_information.error_code // "")}') || {
    health_result provider warn "cannot read the recent requests from the gateway" "sudo onbehalf doctor"
    return 0
  }
  # Per model: an outage of one model must not hide behind traffic to others.
  jq -c --argjson min "$HEALTH_MIN_FAILURES" --argjson win "$HEALTH_WINDOW_MIN" '
    def failed: map(select((.ok | not) and .provider));
    [group_by(.model)[] | (failed) as $f | select(($f | length) >= $min and ($f | length) * 2 >= length)
      | "\(.[0].model): \($f | length) of \(length) failed (\($f | map(.code) | unique | join(", ")))"] as $bad
    | if ($bad | length) > 0 then
        {id: "provider", status: "fail",
         text: "the model provider failed recent requests in the last \($win) minutes: \($bad | join("; "))",
         fix: "sudo onbehalf report --days 1; see the operator guide, section \"Model access fails\""}
      else
        {id: "provider", status: "ok", fix: "",
         text: "\(length) requests in the last \($win) minutes, \(failed | length) failed at the provider"}
      end' <<<"$logs"
}

health_keys() {
  local u bad=()
  for u in $(people); do
    gateway_call "$(home_of "$u")/.config/onbehalf/gateway.key" GET /v1/models >/dev/null 2>&1 || bad+=("$u")
  done
  if [ ${#bad[@]} = 0 ]; then
    health_result keys ok "the gateway accepts the key of every user"
  else
    health_result keys fail "the gateway does not accept the key of: ${bad[*]}" "sudo onbehalf doctor --user NAME"
  fi
}

# One short model request with the probe key, to the stack default model.
health_probe() {
  local model out
  model=$(stack_default_model "$ONBEHALF_STACK/current" 2>/dev/null) || {
    health_result probe fail "the shared stack has no model to probe" "sudo onbehalf stack install DIR"
    return 0
  }
  if [ ! -s "$HEALTH_PROBE_KEY" ]; then
    health_probe_key || {
      health_result probe fail "cannot create the probe key" "sudo onbehalf health on --probe"
      return 0
    }
  fi
  if out=$(model_access_check "$HEALTH_PROBE_KEY" "$model" "$HEALTH_PROBE_USER" 2>&1); then
    health_result probe ok "$model answered the probe"
  else
    out=$(grep -m1 '✗' <<<"$out" | sed 's/^ *✗ *//')
    health_result probe fail "probe of $model: ${out:-no answer}" "sudo onbehalf doctor --model-check"
  fi
}

# The probe key: inference only, owned by root, not a user.
health_probe_key() {
  local key
  key=$(gateway_admin POST /key/generate "$(jq -nc --arg u "$HEALTH_PROBE_USER" --arg a "$HEALTH_PROBE_USER@$(uname -n)" \
    --argjson routes "$(gateway_user_routes)" '{user_id: $u, key_alias: $a, allowed_routes: $routes,
      metadata: {onbehalf: "health probe"}}')" | jq -er .key) || return 1
  (
    umask 077
    printf '%s\n' "$key" >"$HEALTH_PROBE_KEY"
  )
}

health_print() {
  local r=$1 status text fix
  heading "onbehalf health"
  while IFS=$'\t' read -r status text fix; do
    case $status in
      ok) ok "$text" ;;
      warn) warn "$text" ;;
      *) err "$text" ;;
    esac
    [ -z "$fix" ] || fix "$fix"
  done < <(jq -r '.checks[] | [.status, .text, .fix] | @tsv' <<<"$r")
  summary
}

# Keep the result; on a change of the problems, log and post an alert. The
# alerted problems are kept only when the post worked, so a failed post is
# sent again at the next run.
health_record() {
  local r=$1 problems before msg
  problems=$(jq -c '[.checks[] | select(.status != "ok") | "\(.id):\(.status)"] | sort' <<<"$r")
  before=$(jq -c '.alerted // []' "$HEALTH_STATE" 2>/dev/null) || before='[]'
  if [ "$problems" != "$before" ]; then
    msg=$(health_message "$r")
    logger -t onbehalf -p "daemon.$([ "$problems" = '[]' ] && echo info || echo err)" "$(tr '\n' ' ' <<<"$msg")" 2>/dev/null || true
    if [ -n "$ONBEHALF_HEALTH_WEBHOOK" ] && ! health_post "$msg" "$(jq -c '[.checks[] | select(.status != "ok")]' <<<"$r")"; then
      logger -t onbehalf -p daemon.err "health: the webhook did not accept the alert" 2>/dev/null || true
      problems=$before
    fi
  fi
  install -d -m 0755 "$(dirname "$HEALTH_STATE")"
  jq --argjson a "$problems" '. + {alerted: $a}' <<<"$r" >"$HEALTH_STATE.new"
  mv "$HEALTH_STATE.new" "$HEALTH_STATE"
}

health_message() {
  jq -r '
    [.checks[] | select(.status != "ok")] as $p
    | if ($p | length) == 0 then "onbehalf on \(.host): all health checks pass again"
      else "onbehalf on \(.host): \($p | length) problem(s)\n"
        + ($p | map("\(if .status == "fail" then "✗" else "!" end) \(.text)" + (if .fix != "" then " (fix: \(.fix))" else "" end)) | join("\n"))
      end' <<<"$1"
}

# health_post TEXT PROBLEMS_JSON: post to the webhook. The URL goes to curl
# through a file descriptor, never on a command line.
health_post() {
  local body
  case $ONBEHALF_HEALTH_FORMAT in
    teams)
      body=$(jq -nc --arg t "$1" '{type: "message", attachments: [{
        contentType: "application/vnd.microsoft.card.adaptive",
        content: {type: "AdaptiveCard", version: "1.4", "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
          body: [$t | split("\n") | to_entries[] | {type: "TextBlock", text: .value, wrap: true,
            weight: (if .key == 0 then "Bolder" else "Default" end)}]}}]}')
      ;;
    *) body=$(jq -nc --arg t "$1" --argjson p "$2" '{text: $t, problems: $p}') ;;
  esac
  curl -fsS --max-time 15 -o /dev/null -K <(printf 'url = "%s"\n' "$ONBEHALF_HEALTH_WEBHOOK") \
    -H 'Content-Type: application/json' --data-binary @- <<<"$body" 2>/dev/null
}

health_enable() {
  while [ $# -gt 0 ]; do
    case $1 in
      --every)
        [[ ${2:-} =~ ^[0-9]+$ ]] && [ "$2" -ge 1 ] && [ "$2" -le 1440 ] || die "give --every a number of minutes from 1 to 1440"
        ONBEHALF_HEALTH_EVERY=$2
        shift 2
        ;;
      --webhook)
        [[ ${2:-} =~ ^https?://[^[:space:]\"]+$ ]] || die "give --webhook an http(s) URL"
        ONBEHALF_HEALTH_WEBHOOK=$2
        shift 2
        ;;
      --no-webhook)
        ONBEHALF_HEALTH_WEBHOOK=''
        shift
        ;;
      --format)
        case ${2:-} in slack | teams) ONBEHALF_HEALTH_FORMAT=$2 ;; *) die "--format is slack or teams" ;; esac
        shift 2
        ;;
      --probe)
        ONBEHALF_HEALTH_PROBE=yes
        shift
        ;;
      --no-probe)
        ONBEHALF_HEALTH_PROBE=no
        shift
        ;;
      *) health_usage ;;
    esac
  done
  heading "Health checks: every $ONBEHALF_HEALTH_EVERY minutes"
  ONBEHALF_HEALTH=yes
  health_save
  ok "saved $HEALTH_CONF (root only)"
  if [ -n "$ONBEHALF_HEALTH_WEBHOOK" ]; then
    ok "alerts go to the webhook ($ONBEHALF_HEALTH_FORMAT format) when problems start or stop"
    info "to send a test alert: sudo onbehalf health alert-test"
  else
    info "no webhook: changes go to the journal only (journalctl -t onbehalf)"
  fi
  if [ "$ONBEHALF_HEALTH_PROBE" = yes ]; then
    if [ -s "$HEALTH_PROBE_KEY" ] || health_probe_key; then
      ok "the probe sends one short model request at each run, with its own key ($HEALTH_PROBE_KEY)"
    else
      err "cannot create the probe key"
      fix "sudo onbehalf doctor, then: sudo onbehalf health on --probe"
    fi
  else
    info "no model probe: onbehalf finds provider problems only from real requests"
  fi
  health_timer_install "$(readlink -f "$0")"
}

health_disable() {
  heading "Health checks: off"
  ONBEHALF_HEALTH=no
  health_save
  rm -f "$ENROLL_UNITS/onbehalf-health.service" "$ENROLL_UNITS/onbehalf-health.timer"
  if [ -d /run/systemd/system ]; then
    systemctl disable --now onbehalf-health.timer >/dev/null 2>&1 || true
    systemctl daemon-reload
  fi
  ok "removed the health timer"
  if [ -s "$HEALTH_PROBE_KEY" ]; then
    gateway_admin POST /key/delete "$(jq -nc --arg k "$(<"$HEALTH_PROBE_KEY")" '{keys: [$k]}')" >/dev/null 2>&1 \
      && rm -f "$HEALTH_PROBE_KEY" && ok "revoked the probe key"
  fi
  info "to check manually at any time: sudo onbehalf health"
}

health_timer_install() {
  cat >"$ENROLL_UNITS/onbehalf-health.service" <<EOF
[Unit]
Description=onbehalf: health checks, alert on change

[Service]
Type=oneshot
ExecStart=$1 health --record
EOF
  cat >"$ENROLL_UNITS/onbehalf-health.timer" <<EOF
[Unit]
Description=onbehalf: health checks every $ONBEHALF_HEALTH_EVERY minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=${ONBEHALF_HEALTH_EVERY}min

[Install]
WantedBy=timers.target
EOF
  chmod 0644 "$ENROLL_UNITS"/onbehalf-health.*
  if [ -d /run/systemd/system ]; then
    systemctl daemon-reload && systemctl enable --now onbehalf-health.timer >/dev/null 2>&1 \
      && systemctl restart onbehalf-health.timer \
      || die "could not start onbehalf-health.timer"
    ok "a timer runs: onbehalf health --record"
  else
    warn "systemd does not run here, so the health timer does not run"
    fix "run 'sudo onbehalf health --record' every $ONBEHALF_HEALTH_EVERY minutes, for example from cron"
  fi
}

# For doctor: is the timer on, and did it run recently?
health_check() {
  health_conf
  if [ "$ONBEHALF_HEALTH" != yes ]; then
    info "health checks are off: sudo onbehalf health on"
    return 0
  fi
  local last age
  if [ -d /run/systemd/system ] && ! systemctl is-enabled onbehalf-health.timer >/dev/null 2>&1; then
    warn "health checks are on, but the timer is not enabled"
    fix "sudo onbehalf health on"
    return 0
  fi
  last=$(jq -r '.time // empty' "$HEALTH_STATE" 2>/dev/null) || last=''
  age=$((($(date +%s) - $(date -d "${last:-@0}" +%s)) / 60))
  if [ -z "$last" ] || [ "$age" -gt $((ONBEHALF_HEALTH_EVERY * 3)) ]; then
    warn "the health checks did not run in the last $((ONBEHALF_HEALTH_EVERY * 3)) minutes"
    fix "systemctl status onbehalf-health.timer"
  else
    ok "health checks every $ONBEHALF_HEALTH_EVERY minutes, last $age minute(s) ago: $(jq -r .status "$HEALTH_STATE")$([ -n "$ONBEHALF_HEALTH_WEBHOOK" ] && echo ", alerts to the webhook")"
  fi
}
