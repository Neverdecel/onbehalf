#!/usr/bin/env bash
# Make the dashboards of dashboards.json in Langfuse, with the API keys of
# .env. Run it as root in /etc/onbehalf-telemetry. Run it again after a
# change: it replaces the dashboards and widgets with the same names.
#
#   ./dashboards.sh [LANGFUSE_URL] [DASHBOARDS_FILE]
#
# The dashboard API of Langfuse is "unstable": a new Langfuse version can
# change it.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
. ./.env
api_url="${1:-http://127.0.0.1:3000}/api/public/unstable"
file=${2:-dashboards.json}
# Read the complete source before any dashboard changes.
jq -e '.dashboards | type == "array" and length > 0' "$file" >/dev/null

# api METHOD PATH [JSON]. The keys go to curl in a file descriptor, never on
# the command line: each account can read the command lines in /proc.
api() {
  curl -fsS -X "$1" "$api_url/$2" -H 'Content-Type: application/json' ${3:+--data "$3"} \
    -K <(printf 'user = "%s:%s"\n' "$LANGFUSE_PUBLIC_KEY" "$LANGFUSE_SECRET_KEY")
}

# ids KIND NAMES: the ids of the dashboards or widgets with one of the names.
ids() {
  local page=1 out
  while :; do
    out=$(api GET "$1?limit=100&page=$page")
    jq -r --argjson names "$2" '.data[] | select(.name as $n | $names | index($n)) | .id' <<<"$out"
    [ "$(jq '.meta.totalPages' <<<"$out")" -gt "$page" ] || break
    page=$((page + 1))
  done
}

for id in $(ids dashboards "$(jq -c '[.dashboards[].name]' "$file")"); do api DELETE "dashboards/$id" >/dev/null; done
for id in $(ids dashboard-widgets "$(jq -c '[.dashboards[].widgets[].name]' "$file")"); do api DELETE "dashboard-widgets/$id" >/dev/null; done

for d in $(seq 0 $(($(jq '.dashboards | length' "$file") - 1))); do
  dashboard=$(api POST dashboards "$(jq -c ".dashboards[$d] | {name, description}" "$file")" | jq -r .id)
  n=0
  while read -r widget; do
    # A widget that groups by the user needs a row limit.
    id=$(api POST dashboard-widgets "$(jq -c '{view: "observations"} + . +
      (if .chartType | test("TIME_SERIES") then {} else {chartConfig: {type: .chartType, row_limit: 50}} end)' <<<"$widget")" | jq -r .id)
    api POST "dashboards/$dashboard/placements" \
      "$(jq -nc --arg w "$id" --argjson x $((n % 2 * 6)) --argjson y $((n / 2 * 6)) '{type: "widget", widgetId: $w, x: $x, y: $y, width: 6, height: 6}')" >/dev/null
    n=$((n + 1))
  done < <(jq -c ".dashboards[$d].widgets[]" "$file")
  echo "made the dashboard \"$(jq -r ".dashboards[$d].name" "$file")\" with $n widgets"
done
