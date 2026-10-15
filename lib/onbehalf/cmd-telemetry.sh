# shellcheck shell=bash
# onbehalf telemetry: send the tool calls and the model steps of each user
# to an OpenTelemetry backend, with the identity of the Unix account.
#
# The operator installs the OTel Collector (otelcol-contrib) and selects the
# backend. onbehalf writes the configuration of the Collector, gives each
# user a personal telemetry key, and links the telemetry plugin into the AI
# harness of each user. The Collector accepts only a valid key, and sets
# user.name from that key: a user cannot send spans as a different user.
# Only OpenCode is supported for now.

TELEMETRY_CONF=${TELEMETRY_CONF:-$ONBEHALF_ETC/telemetry.conf}
# Read by the plugin as the user, so it must not contain a secret.
TELEMETRY_JSON=${TELEMETRY_JSON:-$ONBEHALF_ETC/telemetry.json}
TELEMETRY_DIR=${TELEMETRY_DIR:-$ONBEHALF_ETC/telemetry}
# The group of the Collector service of the otelcol-contrib package.
TELEMETRY_GROUP=${TELEMETRY_GROUP:-otelcol-contrib}
TELEMETRY_PLUGIN="$ONBEHALF_LIB/telemetry/opencode.js"

telemetry_conf() {
  ONBEHALF_TELEMETRY=no ONBEHALF_TELEMETRY_EXPORT='' ONBEHALF_TELEMETRY_PORT=4318
  # shellcheck source=/dev/null
  [ ! -r "$TELEMETRY_CONF" ] || . "$TELEMETRY_CONF"
}

telemetry_on() { telemetry_conf && [ "$ONBEHALF_TELEMETRY" = yes ]; }

telemetry_save() {
  (
    umask 077
    cat >"$TELEMETRY_CONF" <<EOF
# onbehalf telemetry. Change it with: sudo onbehalf telemetry on|off
ONBEHALF_TELEMETRY=$ONBEHALF_TELEMETRY
ONBEHALF_TELEMETRY_EXPORT=$(printf %q "$ONBEHALF_TELEMETRY_EXPORT")
ONBEHALF_TELEMETRY_PORT=$ONBEHALF_TELEMETRY_PORT
EOF
  )
}

telemetry_usage() {
  die "usage: onbehalf telemetry on --export URL [--port PORT] | telemetry off. The authorization header of the backend comes on stdin or in the terminal"
}

cmd_telemetry() {
  need_root
  load_conf
  telemetry_conf
  case ${1:-} in
    on)
      shift
      telemetry_enable "$@"
      ;;
    off)
      [ $# = 1 ] || telemetry_usage
      telemetry_disable
      ;;
    *) telemetry_usage ;;
  esac
}

telemetry_enable() {
  local auth=""
  while [ $# -gt 0 ]; do
    case $1 in
      --export)
        [[ ${2:-} =~ ^https?://[^[:space:]\"]+$ ]] || die "give --export the OTLP/HTTP URL of the backend"
        ONBEHALF_TELEMETRY_EXPORT=${2%/}
        shift 2
        ;;
      --port)
        [[ ${2:-} =~ ^[0-9]+$ ]] && [ "$2" -ge 1024 ] && [ "$2" -le 65535 ] || die "give --port a port from 1024 to 65535"
        ONBEHALF_TELEMETRY_PORT=$2
        shift 2
        ;;
      *) telemetry_usage ;;
    esac
  done
  [ -n "$ONBEHALF_TELEMETRY_EXPORT" ] || telemetry_usage
  [ "$(harness_id)" = opencode ] || die "telemetry supports only OpenCode for now. This host uses $(harness label)"
  getent group "$TELEMETRY_GROUP" >/dev/null \
    || die "the group $TELEMETRY_GROUP of the OTel Collector is not on this host. Install otelcol-contrib first. See the operator guide, section 'Telemetry'"

  heading "Telemetry: tool calls and model steps to $ONBEHALF_TELEMETRY_EXPORT"
  if [ -t 0 ]; then
    info "Some backends use an authorization header, for example 'Basic <base64>' for Langfuse."
    ask_secret auth "Authorization header of the backend (empty for none)"
  else
    auth=$(cat)
  fi
  install -d -o root -g "$TELEMETRY_GROUP" -m 0750 "$TELEMETRY_DIR"
  if [ -n "$auth" ]; then
    printf %s "$auth" | install -o root -g "$TELEMETRY_GROUP" -m 0640 /dev/stdin "$TELEMETRY_DIR/export-auth"
  else
    rm -f "$TELEMETRY_DIR/export-auth"
  fi
  ONBEHALF_TELEMETRY=yes
  telemetry_save
  ok "saved $TELEMETRY_CONF (root only)"
  telemetry_collector_write
  ok "wrote the Collector configuration $TELEMETRY_DIR/otelcol.yaml"
  jq -n --arg url "http://127.0.0.1:$ONBEHALF_TELEMETRY_PORT" '{url: $url}' >"$TELEMETRY_JSON"
  chmod 0644 "$TELEMETRY_JSON"

  local u home
  for u in $(people); do
    home=$(home_of "$u")
    telemetry_user_link "$u" "$home" "$(id -gn "$u")"
  done
  telemetry_users_write
  ok "each user has a personal telemetry key and the telemetry plugin"
  info "the plugin sends tool names, fixed command labels, results, duration and tokens. Never prompts, answers, arguments or tool output"
  info "a runtime that runs now sends spans after its next start: sudo onbehalf restart --all"
  telemetry_reload
  telemetry_check
}

telemetry_disable() {
  heading "Telemetry: off"
  ONBEHALF_TELEMETRY=no
  telemetry_save
  rm -f "$TELEMETRY_JSON"
  local u home
  for u in $(people); do
    home=$(home_of "$u")
    [ "$(link_of "$home/.config/opencode/plugins/onbehalf-telemetry.js")" != "$TELEMETRY_PLUGIN" ] \
      || rm -f "$home/.config/opencode/plugins/onbehalf-telemetry.js"
  done
  : >"$TELEMETRY_DIR/htpasswd" 2>/dev/null || true
  telemetry_reload
  ok "the runtimes send no spans after their next start, and the Collector accepts no key"
  info "the Collector configuration stays in $TELEMETRY_DIR. Stop the Collector if nothing else uses it"
}

# The files of the tool class rules, in order: telemetry/classes.json of
# the shared stack, then the default rules of onbehalf. A team adds only its
# own rules, and a rule of the team comes before a default rule.
telemetry_classes_files() {
  local f="$ONBEHALF_STACK/current/telemetry/classes.json"
  [ ! -e "$f" ] || echo "$f"
  echo "$ONBEHALF_LIB/telemetry/classes.json"
}

# telemetry_classes_valid FILE: {"rules": [RULE...]}. A rule has the class
# read or write, and a pattern for the tool name, for the command, or both.
# The Collector uses Go (RE2) patterns: no lookaround and no back reference.
telemetry_classes_valid() {
  jq -e '
    def pattern: type == "string" and length > 0 and length <= 2000 and
      (test("\\(\\?<?[=!]|\\\\[1-9]") | not) and (try ("" | test(.) | true) catch false);
    type == "object" and (keys == ["rules"]) and (.rules | type == "array" and length > 0) and
    all(.rules[]; type == "object" and (keys - ["class", "tool", "command"] | length == 0) and
      (.class == "read" or .class == "write") and (has("tool") or has("command")) and
      ((has("tool") | not) or (.tool | pattern)) and ((has("command") | not) or (.command | pattern)))
  ' "$1" >/dev/null 2>&1
}

# The OTTL statements of the tool classes, one YAML list item on each line.
# A client cannot give a class: the Collector removes it first. The first
# rule that agrees gives the class. A tool call without a rule is unknown.
# Langfuse can filter only on a metadata key at the top level, so the class
# is also in langfuse.observation.metadata.tool_class.
telemetry_classes_statements() {
  jq -s '{rules: map(.rules) | add}' "$@" | jq -r --arg q "'" '
    def item: "      - " + $q + gsub($q; $q + $q) + $q;
    def tool: "span.attributes[\"gen_ai.operation.name\"] == \"execute_tool\" and span.attributes[\"tool.class\"] == nil";
    ("delete_key(span.attributes, \"tool.class\")" | item),
    ("delete_key(span.attributes, \"langfuse.observation.metadata.tool_class\")" | item),
    (.rules[] | . as $r | [tool] +
      (if .tool then ["IsMatch(span.attributes[\"gen_ai.tool.name\"], " + ("^(?:" + .tool + ")$" | tojson) + ")"] else [] end) +
      (if .command then ["IsMatch(span.attributes[\"process.command_line\"], " + (.command | tojson) + ")"] else [] end) |
      "set(span.attributes[\"tool.class\"], " + ($r.class | tojson) + ") where " + join(" and ") | item),
    ("set(span.attributes[\"tool.class\"], \"unknown\") where " + tool | item),
    ("set(span.attributes[\"langfuse.observation.metadata.tool_class\"], span.attributes[\"tool.class\"]) where span.attributes[\"tool.class\"] != nil" | item)
  '
}

# For stack install: the Collector uses the tool classes of the new stack.
telemetry_stack_changed() {
  telemetry_on || return 0
  telemetry_collector_write
  telemetry_reload
  ok "the Collector uses the tool classes of $(telemetry_classes_files | paste -sd' ' | sed 's/ / and /')"
}

# The Collector: an OTLP/HTTP receiver on the loopback address that accepts
# only the telemetry keys of the users, then the backend of the operator.
telemetry_collector_write() {
  local headers="" classes
  local files
  mapfile -t files < <(telemetry_classes_files)
  classes=$(telemetry_classes_statements "${files[@]}") || die "could not read the tool classes in ${files[*]}"
  if [ -e "$TELEMETRY_DIR/export-auth" ]; then
    headers=$'\n    headers:\n      authorization: ${file:'"$TELEMETRY_DIR"$'/export-auth}'
  fi
  touch "$TELEMETRY_DIR/htpasswd"
  chown root:"$TELEMETRY_GROUP" "$TELEMETRY_DIR/htpasswd"
  chmod 0640 "$TELEMETRY_DIR/htpasswd"
  # Keep the secret across configuration reloads so pseudonyms stay stable.
  if [ ! -s "$TELEMETRY_DIR/identity-salt" ]; then
    openssl rand -hex 32 | tr -d '\n' | install -o root -g "$TELEMETRY_GROUP" -m 0640 /dev/stdin "$TELEMETRY_DIR/identity-salt"
  fi
  cat >"$TELEMETRY_DIR/otelcol.yaml.new" <<EOF
# Written by onbehalf telemetry on. Do not change it: onbehalf writes it again.
# onbehalf telemetry schema: 2
extensions:
  basicauth/onbehalf:
    htpasswd:
      file: $TELEMETRY_DIR/htpasswd

receivers:
  otlp/onbehalf:
    protocols:
      http:
        endpoint: 127.0.0.1:$ONBEHALF_TELEMETRY_PORT
        include_metadata: true
        auth:
          authenticator: basicauth/onbehalf

processors:
  # The identity comes from the key, never from the spans of the user.
  # Backends such as Langfuse read the user from each span, not from the
  # resource. A user value of the client is removed first.
  attributes/onbehalf:
    actions:
      - pattern: ^(langfuse\.user\..*|enduser\..*)$
        action: delete
      - key: user.id
        from_context: auth.username
        action: upsert
      - key: user.name
        from_context: auth.username
        action: upsert
  # The class of each tool call: read, write or unknown.
  transform/onbehalf:
    error_mode: ignore
    trace_statements:
$classes
  # Fail closed if the privacy transform fails. The backend gets no account
  # name, host name, raw command, arguments, output or unknown attributes.
  transform/onbehalf-privacy:
    error_mode: propagate
    trace_statements:
      - 'set(span.attributes["user.id"], SHA256(Concat([span.attributes["user.name"], "\${file:$TELEMETRY_DIR/identity-salt}"], ":")))'
      - 'keep_keys(resource.attributes, ["service.name", "service.version", "onbehalf.harness"])'
      - >-
        keep_keys(span.attributes, ["user.id", "session.id", "gen_ai.operation.name", "gen_ai.agent.name",
        "gen_ai.tool.name", "gen_ai.tool.type", "gen_ai.tool.call.id", "gen_ai.conversation.id",
        "gen_ai.provider.name", "gen_ai.request.model", "gen_ai.response.finish_reasons",
        "gen_ai.usage.input_tokens", "gen_ai.usage.output_tokens", "gen_ai.usage.cache_read.input_tokens",
        "gen_ai.usage.cache_creation.input_tokens", "gen_ai.usage.reasoning.output_tokens",
        "process.exit.code", "error.type", "tool.class", "langfuse.release", "langfuse.version",
        "langfuse.trace.metadata.stack_id", "langfuse.trace.metadata.telemetry_version",
        "langfuse.trace.metadata.harness_version", "langfuse.trace.metadata.onbehalf_version",
        "langfuse.observation.type", "langfuse.observation.completion_start_time",
        "langfuse.observation.metadata.tool_class", "langfuse.observation.metadata.skill_name",
        "langfuse.observation.metadata.command_summary", "langfuse.observation.metadata.execution_observed",
        "langfuse.observation.metadata.execution_match", "langfuse.observation.metadata.tool_interruption_count",
        "langfuse.observation.metadata.tool_unobserved_count",
        "langfuse.observation.metadata.uncached_input_tokens", "langfuse.observation.metadata.text_output_tokens",
        "langfuse.observation.metadata.time_to_first_token_ms", "langfuse.observation.metadata.time_to_first_text_ms",
        "langfuse.observation.metadata.retry_count", "langfuse.observation.metadata.retry_attempt",
        "langfuse.observation.metadata.stream_boundary_observed", "langfuse.observation.metadata.task_result",
        "langfuse.observation.metadata.tool_call_count", "langfuse.observation.metadata.tool_failure_count",
        "langfuse.observation.metadata.model_step_count", "langfuse.observation.metadata.telemetry_export_failures",
        "langfuse.observation.metadata.telemetry_dropped_spans", "langfuse.observation.metadata.telemetry_event_errors"])
  batch: {}

exporters:
  otlp_http/backend:
    endpoint: $ONBEHALF_TELEMETRY_EXPORT$headers

service:
  # No metrics of the Collector itself: they use port 8888 of the host.
  telemetry:
    metrics:
      level: none
  extensions: [basicauth/onbehalf]
  pipelines:
    traces:
      receivers: [otlp/onbehalf]
      processors: [attributes/onbehalf, transform/onbehalf, transform/onbehalf-privacy, batch]
      exporters: [otlp_http/backend]
EOF
  chown root:"$TELEMETRY_GROUP" "$TELEMETRY_DIR/otelcol.yaml.new"
  chmod 0640 "$TELEMETRY_DIR/otelcol.yaml.new"
  mv "$TELEMETRY_DIR/otelcol.yaml.new" "$TELEMETRY_DIR/otelcol.yaml"
}

# Give a user a personal telemetry key and link the plugin into OpenCode.
# A personal plugin with the same name stays.
telemetry_user_link() {
  local u=$1 home=$2 group=$3 key="$2/.config/onbehalf/telemetry.key" dir="$2/.config/opencode/plugins"
  if [ ! -s "$key" ]; then
    openssl rand -hex 32 | tr -d '\n' | install -o "$u" -g "$group" -m 0600 /dev/stdin "$key"
  fi
  [ -e "$dir" ] || install -d -o "$u" -g "$group" -m 0700 "$dir"
  harness_link_item "$u" "$group" no "$TELEMETRY_PLUGIN" "$dir/onbehalf-telemetry.js"
}

# The users that the Collector accepts: one line for each user with a key.
# A user without a gateway key is not in people, so the Collector refuses
# a removed or pruned user.
telemetry_users_write() {
  local u key tmp
  tmp=$(mktemp "$TELEMETRY_DIR/.htpasswd.XXXXXX")
  for u in $(people); do
    key="$(home_of "$u")/.config/onbehalf/telemetry.key"
    [ -s "$key" ] || continue
    printf '%s:%s\n' "$u" "$(openssl passwd -6 -stdin <"$key")" >>"$tmp"
  done
  chown root:"$TELEMETRY_GROUP" "$tmp"
  chmod 0640 "$tmp"
  mv "$tmp" "$TELEMETRY_DIR/htpasswd"
}

# The Collector reads its configuration again at SIGHUP.
telemetry_reload() { pkill -HUP -x otelcol-contrib 2>/dev/null || true; }

# For user add and enroll: a user without a key or not in the Collector
# users gets them. Each login enrolls again, so the Collector reloads only
# for a change.
telemetry_user_add() {
  telemetry_on || return 0
  local u=$1 home=$2 group=$3
  [ "$(harness_id)" = opencode ] || return 0
  telemetry_user_link "$u" "$home" "$group"
  if ! grep -q "^$u:" "$TELEMETRY_DIR/htpasswd" 2>/dev/null; then
    telemetry_users_write
    telemetry_reload
  fi
  ok "has a personal telemetry key"
}

# For user remove and prune: the Collector refuses the key of the user.
telemetry_user_remove() {
  telemetry_on || return 0
  telemetry_users_write
  telemetry_reload
}

# For doctor and telemetry on: does the Collector run with the configuration?
telemetry_check() {
  telemetry_conf
  if [ "$ONBEHALF_TELEMETRY" != yes ]; then
    info "telemetry is off: sudo onbehalf telemetry on --export URL"
    return 0
  fi
  if ! grep -qxF '# onbehalf telemetry schema: 2' "$TELEMETRY_DIR/otelcol.yaml" 2>/dev/null \
    || [ ! -s "$TELEMETRY_DIR/identity-salt" ]; then
    warn "the telemetry configuration is outdated; the Collector can still export account and host names"
    fix "run sudo onbehalf telemetry on --export $ONBEHALF_TELEMETRY_EXPORT with the existing backend authorization, then reload the Collector"
  fi
  local code
  # After a SIGHUP, the Collector starts again: give it a few seconds.
  for _ in 1 2 3 4 5; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
      "http://127.0.0.1:$ONBEHALF_TELEMETRY_PORT/v1/traces" 2>/dev/null) || code=000
    [ "$code" = 000 ] || break
    sleep 1
  done
  if [ "$code" = 401 ]; then
    ok "the OTel Collector accepts telemetry on port $ONBEHALF_TELEMETRY_PORT, only with a key, to $ONBEHALF_TELEMETRY_EXPORT"
    info "the tool classes come from $(telemetry_classes_files | paste -sd' ' | sed 's/ / and /')"
  elif [ "$code" = 000 ]; then
    err "the OTel Collector does not answer on port $ONBEHALF_TELEMETRY_PORT"
    fix "start otelcol-contrib with --config=$TELEMETRY_DIR/otelcol.yaml. See the operator guide, section 'Telemetry'"
  else
    err "port $ONBEHALF_TELEMETRY_PORT accepts telemetry without a key (HTTP $code): it is not the Collector of onbehalf"
    fix "start otelcol-contrib with --config=$TELEMETRY_DIR/otelcol.yaml. See the operator guide, section 'Telemetry'"
  fi
}

# For doctor and status: the user has a key and the plugin. A user cannot
# read the settings, so the public file of the plugin tells that it is on.
telemetry_user_check() {
  local u=$1 home=$2
  [ -e "$TELEMETRY_JSON" ] || return 0
  if [ -s "$home/.config/onbehalf/telemetry.key" ] \
    && [ "$(link_of "$home/.config/opencode/plugins/onbehalf-telemetry.js")" = "$TELEMETRY_PLUGIN" ]; then
    ok "OpenCode sends the tool calls to the telemetry of the host"
  else
    warn "OpenCode does not send the tool calls to the telemetry of the host"
    if [ "$(id -u)" = 0 ]; then
      fix "sudo onbehalf user add $u"
    else
      fix "ask your operator to run: sudo onbehalf user add $u"
    fi
  fi
}
