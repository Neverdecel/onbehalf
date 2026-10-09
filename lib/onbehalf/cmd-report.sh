# shellcheck shell=bash disable=SC2154 # colours come from ui.sh
# onbehalf report: who uses the agents, how much, and what fails. For the
# operator, read-only. Joins this host (users, logins, work tools) with the
# gateway (keys, spend logs). Shows metadata only: never what a user asked
# or what the model answered, also when the gateway stores it.

REPORT_MAX_DAYS=90
# Gateway users that are services, not users: one name on each line. The
# health probe is always a service.
REPORT_SERVICES=${REPORT_SERVICES:-$ONBEHALF_ETC/report-services}

# jq formatters for the readable report.
REPORT_FMT='
  def day: if . then .[0:10] else "-" end;
  def tok: if . >= 1000000 then "\(. / 100000 | floor / 10)M"
           elif . >= 1000 then "\(. / 100 | floor / 10)k" else tostring end;
  def usd: if . == 0 then "-" elif . < 0.01 then "<$0.01"
           else "$\(. * 100 | round / 100 | tostring
                    | if test("\\.\\d$") then . + "0" elif test("\\.") then . else . + ".00" end)" end;
'

cmd_report() {
  need_root
  load_conf
  local days=7 json=no
  while [ $# -gt 0 ]; do
    case $1 in
      --days)
        [[ ${2:-} =~ ^[0-9]+$ ]] && [ "$2" -ge 1 ] && [ "$2" -le "$REPORT_MAX_DAYS" ] \
          || die "give --days a number from 1 to $REPORT_MAX_DAYS"
        days=$2
        shift 2
        ;;
      --json)
        json=yes
        shift
        ;;
      *) die "usage: onbehalf report [--days N] [--json]" ;;
    esac
  done

  local tmp start end
  REPORT_TMP=$(mktemp -d)
  trap 'rm -rf "$REPORT_TMP"' EXIT
  tmp=$REPORT_TMP
  start=$(date -u -d "-$days days" '+%F %T')
  end=$(date -u -d '+1 minute' '+%F %T')

  report_users >"$tmp/users.json"
  report_removed >"$tmp/removed.json"
  report_services >"$tmp/services.json"
  report_gateway_pages "/key/list?return_full_object=true" keys \
    '{user: (.user_id // ""), created: .created_at, last_active}' >"$tmp/keys.json" \
    || die "cannot read the keys from the gateway. Check: sudo onbehalf doctor"
  report_gateway_pages "/spend/logs/v2?start_date=$(report_urlenc "$start")&end_date=$(report_urlenc "$end")" data \
    '{user: (.user // ""), model: (.model_group // .model), status, tokens: (.total_tokens // 0), spend: (.spend // 0),
      time: .startTime, error: (.metadata.error_information // null
        | if . then {code: (.normalized_error // .error_code // "error"),
                     message: ((.error_message // "")
                       | (capture("\"message\":\\s*\"(?<m>[^\"]+)\"").m // split("\n")[0] // "") | .[0:160])}
                  else null end)}' \
    >"$tmp/logs.json" \
    || die "cannot read the cost logs from the gateway. Check: sudo onbehalf doctor"

  jq -n --argjson days "$days" --arg start "$start" --arg end "$end" \
    --slurpfile users "$tmp/users.json" --slurpfile keys "$tmp/keys.json" --slurpfile logs "$tmp/logs.json" \
    --slurpfile removed "$tmp/removed.json" --slurpfile services "$tmp/services.json" \
    -f /dev/stdin >"$tmp/report.json" <<'JQ'
def usage: {requests: length, failed: (map(select(.status != "success")) | length),
            tokens: (map(.tokens) | add // 0), spend: (map(.spend) | add // 0)};
def latest: map(select(. != null)) | max;
($logs | add // []) as $logs
| ($keys | add // []) as $keys
| ($services | add // []) as $services
| ($users | map(.name)) as $names
| ($removed | map({key: .name, value: .removed}) | from_entries) as $removed
| ($logs | group_by(.user) | map({key: .[0].user, value: .}) | from_entries) as $by_user
| ($by_user | keys | map(select(. as $u | $names | index($u) | not))) as $rest
| def row($u): ($by_user[$u] // []) as $l
    | ($keys | map(select(.user == $u))) as $k
    | {joined: ($k | map(.created) | min), last_request: ([$k[].last_active] + [$l[].time] | latest)}
      + ($l | usage);
{
  window: {days: $days, start: $start, end: $end},
  users: [$users[] | . + row(.name)],
  # Each other user of the gateway is a service, a past user or unknown.
  # A user that is not on this host is not always a past user.
  services: [$rest[] | select(. as $u | $services | index($u)) | {name: .} + row(.)],
  past: [$rest[] | select(. as $u | ($services | index($u) | not) and $removed[$u])
         | {name: ., removed: $removed[.]} + row(.)],
  other: [$rest[] | select(. as $u | ($services | index($u) | not) and ($removed[$u] | not))
          | {name: (if . == "" then "(no user)" else . end)} + row(.)],
  models: [$logs | group_by(.model)[]
           | {model: .[0].model,
              users: (map(.user) | unique | map(select(. as $u | ($names | index($u)) or $removed[$u])) | length)}
             + usage]
          | sort_by(-.requests),
  errors: [$logs | map(select(.error)) | group_by([.user, .model, .error.code])[]
           | {user: .[0].user, model: .[0].model, error: .[0].error.code, count: length,
              last: (map(.time) | max), message: (max_by(.time).error.message)}]
          | sort_by(-.count)
}
| .summary = (.users as $p | {
    users: ($p | length),
    logged_in: ($p | map(select(.last_login)) | length),
    tools_ready: ($p | map(select(.tools.total > 0 and .tools.ready == .tools.total)) | length),
    used_a_model: ($p | map(select(.last_request)) | length),
    active: ($p | map(select(.requests > 0)) | length)})
JQ

  if [ "$json" = yes ]; then
    cat "$tmp/report.json"
  else
    report_print "$tmp/report.json"
  fi
}

# One JSON object per user on this host: role, last login, work tools.
report_users() {
  local u home login tools owner
  for u in $(people); do
    home=$(home_of "$u")
    login=$(report_last_login "$u" "$home")
    owner=$(owner_of "$u")
    # Work tools keep their logins private to the user: ask as the user.
    tools=$(as_user "$u" "timeout 60 onbehalf tools --list" 2>/dev/null) || tools=''
    jq -nc --arg name "$u" --arg owner "$owner" --arg login "$login" --arg tools "$tools" '
      def opt: if . == "" then null else . end;
      ($tools | split("\n") | map(select(. != "") | split("\t") | {id: .[0], state: .[1]})
        | map(select(.state != "missing"))) as $t
      | {name: $name, agent_of: ($owner | opt), last_login: ($login | opt),
         tools: {ready: ($t | map(select(.state == "ok")) | length), total: ($t | length),
                 todo: ($t | map(select(.state != "ok") | .id))}}'
  done
}

# One JSON object per past user: name, and when onbehalf revoked the access.
report_removed() {
  local f
  for f in "$REMOVED_STATE"/*; do
    [ -f "$f" ] || continue
    jq -nc --arg name "${f##*/}" --arg t "$(date -u -r "$f" '+%FT%TZ')" '{name: $name, removed: $t}'
  done
}

# The names of the services, as one JSON array.
report_services() {
  {
    echo "$HEALTH_PROBE_USER"
    [ ! -r "$REPORT_SERVICES" ] || sed 's/#.*//' "$REPORT_SERVICES"
  } \
    | tr -s ' \t' '\n' | jq -Rsc 'split("\n") | map(select(. != "")) | unique'
}

# The newest of: the login mark of onbehalf login (every interactive login),
# the auto-enroll mark (every SSH login) and the login records of the host
# (wtmp, where it exists). Empty if none has a login.
report_last_login() {
  local f t newest=0 seen
  for f in "$2/.config/onbehalf/last-login" "$ENROLL_STATE/$1"; do
    t=$(stat -c %Y "$f" 2>/dev/null) || continue
    [ "$t" -le "$newest" ] || newest=$t
  done
  # Only lines of this account: last also prints "wtmp begins DATE".
  seen=$(last -w -n 1 --time-format iso -- "$1" 2>/dev/null | awk -v u="$1" '$1 == u' \
    | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9:]{5}' | head -1) || seen=''
  if [ -n "$seen" ] && t=$(date -d "$seen" +%s 2>/dev/null) && [ "$t" -gt "$newest" ]; then
    newest=$t
  fi
  [ "$newest" = 0 ] || date -u -d "@$newest" '+%FT%TZ'
}

# report_gateway_pages PATH FIELD JQ: every page of a paged admin API list,
# as one JSON array of FIELD items, each mapped with JQ.
report_gateway_pages() {
  local path=$1 field=$2 map=$3 page=1 pages=1 out all='' sep='?'
  [[ $path != *\?* ]] || sep='&'
  while [ "$page" -le "$pages" ]; do
    out=$(gateway_admin GET "$path${sep}page=$page&page_size=100&size=100") || return 1
    pages=$(jq -r '.total_pages // 1' <<<"$out")
    all+=$(jq -c --arg f "$field" "[.[\$f][] | $map]" <<<"$out")$'\n'
    page=$((page + 1))
  done
  jq -sc 'add // []' <<<"$all"
}

report_urlenc() { jq -rn --arg s "$1" '$s | @uri'; }

report_print() {
  local r=$1
  heading "onbehalf report: the last $(jq -r .window.days "$r") days"
  info "from $(jq -r .window.start "$r") to now (UTC). The gateway writes its logs in approximately one minute"

  heading "Adoption"
  jq -r '.summary | "  \(.users) users · \(.logged_in) logged in · \(.tools_ready) with work tools ready · \(.used_a_model) used a model · \(.active) active in this period"' "$r"
  jq -r '
    def names(f): [.users[] | select(f) | .name] | join(", ");
    [ (names(.last_login == null) | select(. != "") | "no login recorded: \(.)"),
      (names(.tools.ready < .tools.total) | select(. != "") | "work tools not ready: \(.)"),
      (names(.last_request == null) | select(. != "") | "never sent a model request: \(.)") ][]
    | "  · \(.)"' "$r" | report_dim

  heading "Current users"
  if [ "$(jq '.users | length' "$r")" = 0 ]; then
    info "no users on this host"
  else
    jq -r "$REPORT_FMT"'
      ["USER", "JOINED", "LAST LOGIN", "TOOLS", "LAST REQUEST", "REQUESTS", "FAILED", "TOKENS", "SPEND"],
      (.users[]
       | [.name + (if .agent_of then " (runtime account)" else "" end),
          (.joined | day), (.last_login | day), "\(.tools.ready)/\(.tools.total)",
          (.last_request | day), (.requests | tostring), (.failed | tostring),
          (.tokens | tok), (.spend | usd)])
      | @tsv' "$r" | report_table
    jq -r '.users[] | select(.agent_of) | "  · \(.name) is the runtime account of the operator \(.agent_of)"' "$r" | report_dim
  fi

  heading "Past users"
  if [ "$(jq '.past | length' "$r")" = 0 ]; then
    info "no model use of past users in this period"
  else
    jq -r "$REPORT_FMT"'
      ["USER", "REMOVED", "LAST REQUEST", "REQUESTS", "FAILED", "TOKENS", "SPEND"],
      (.past[] | [.name, (.removed | day), (.last_request | day), (.requests | tostring),
                  (.failed | tostring), (.tokens | tok), (.spend | usd)])
      | @tsv' "$r" | report_table
    info "onbehalf revoked the access of these users. The gateway keeps their model use"
  fi

  heading "Service usage"
  if [ "$(jq '.services | length' "$r")" = 0 ]; then
    info "no model use of services in this period"
  else
    jq -r --arg probe "$HEALTH_PROBE_USER" "$REPORT_FMT"'
      ["SERVICE", "LAST REQUEST", "REQUESTS", "FAILED", "TOKENS", "SPEND"],
      (.services[] | [.name + (if .name == $probe then " (health probe)" else "" end),
                      (.last_request | day), (.requests | tostring), (.failed | tostring),
                      (.tokens | tok), (.spend | usd)])
      | @tsv' "$r" | report_table
  fi

  if [ "$(jq '.other | length' "$r")" != 0 ]; then
    heading "Other usage"
    jq -r "$REPORT_FMT"'
      ["NAME", "LAST REQUEST", "REQUESTS", "FAILED", "TOKENS", "SPEND"],
      (.other[] | [.name, (.last_request | day), (.requests | tostring),
                   (.failed | tostring), (.tokens | tok), (.spend | usd)])
      | @tsv' "$r" | report_table
    info "onbehalf does not know these names: they are not current users, past users or services"
    info "if a name is a service, add it to $REPORT_SERVICES"
  fi

  heading "Models"
  if [ "$(jq '.models | length' "$r")" = 0 ]; then
    info "no model requests in this period"
  else
    jq -r "$REPORT_FMT"'
      ["MODEL", "USERS", "REQUESTS", "FAILED", "TOKENS", "SPEND"],
      (.models[] | [.model, (.users | tostring), (.requests | tostring), (.failed | tostring),
                    (.tokens | tok), (.spend | usd)])
      | @tsv' "$r" | report_table
  fi

  heading "Failed requests"
  if [ "$(jq '.errors | length' "$r")" = 0 ]; then
    ok "no failed requests in this period"
  else
    jq -r '.errors[] | "\(.user)\t\(.model)\t\(.error)\t\(.count)\t\(.last[0:16] | sub("T"; " "))\t\(.message)"' "$r" \
      | while IFS=$'\t' read -r p m e n t msg; do
        warn "$p · $m · $e · $n× (last $t)"
        [ -z "$msg" ] || info "$msg"
      done
    info "to see the full failure of one user: sudo onbehalf doctor --user NAME --model MODEL"
  fi
  printf '\n'
}

# Align tab-separated rows; the first row is the header.
report_table() {
  awk -F'\t' -v b="$_b" -v z="$_0" '
    { for (i = 1; i <= NF; i++) { c[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) } n = NF; rows = NR }
    END {
      for (r = 1; r <= rows; r++) {
        line = "  "
        for (i = 1; i <= n; i++) line = line sprintf(i < n ? "%-" w[i] + 2 "s" : "%s", c[r, i])
        print (r == 1 ? b line z : line)
      }
    }'
}

report_dim() { sed "s/^/$_d/; s/\$/$_0/"; }
