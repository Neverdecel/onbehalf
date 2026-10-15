#!/usr/bin/env bash
# onbehalf telemetry with OpenCode. The plugin sends a span for each tool
# call and each model step to the OTel Collector. The Collector accepts only
# the telemetry key of a user and sets user.name from it. A test backend on
# the host keeps what the Collector exports. Only a test host with the OTel
# Collector runs this check.
set -uo pipefail
. /src/test/lib.sh

check "the telemetry plugin passes the synthetic checks" node --experimental-vm-modules /src/test/fixtures/telemetry-plugin.mjs

# Invalid dashboard sources must stop before the publisher can make a write.
dashboard_test=$(mktemp -d)
cp /src/examples/telemetry/dashboards.sh "$dashboard_test/dashboards.sh"
printf 'LANGFUSE_PUBLIC_KEY=TEST_ONLY_KEY\nLANGFUSE_SECRET_KEY=TEST_ONLY_KEY\n' >"$dashboard_test/.env"
echo '{"dashboards": []}' >"$dashboard_test/empty.json"
mkdir "$dashboard_test/bin"
cat >"$dashboard_test/bin/curl" <<'EOF'
#!/usr/bin/env bash
touch "$DASHBOARD_TEST_CALLED"
echo '{"id": "test-dashboard", "data": [], "meta": {"totalPages": 1}}'
EOF
chmod +x "$dashboard_test/bin/curl"
if DASHBOARD_TEST_CALLED="$dashboard_test/called" PATH="$dashboard_test/bin:$PATH" bash "$dashboard_test/dashboards.sh" http://127.0.0.1:1 "$dashboard_test/empty.json" >/dev/null 2>&1; then
  check "the dashboard publisher refuses an empty source" false
else
  check "the dashboard publisher refuses an empty source" true
fi
check "the invalid dashboard source sends no API request" test ! -e "$dashboard_test/called"
mkdir "$dashboard_test/caller"
echo '{"dashboards": [{"name": "relative-source", "description": "Test", "widgets": []}]}' >"$dashboard_test/caller/source.json"
echo '{"dashboards": [{"name": "wrong-source", "description": "Test", "widgets": []}]}' >"$dashboard_test/source.json"
out=$(cd "$dashboard_test/caller" && DASHBOARD_TEST_CALLED="$dashboard_test/called" PATH="$dashboard_test/bin:$PATH" bash "$dashboard_test/dashboards.sh" http://127.0.0.1:1 source.json 2>&1)
check "the dashboard source resolves from the caller directory" grep -q 'relative-source' <<<"$out"
check "the dashboard source does not resolve from the script directory" bash -c '! grep -q wrong-source <<<"$1"' _ "$out"
rm -rf "$dashboard_test"

if ! command -v otelcol-contrib >/dev/null; then
  echo "  skip  the OTel Collector is not installed on this test host"
  exit "$FAILED"
fi

dir=/etc/onbehalf/telemetry
backend=$(mktemp -d)
chmod 0755 "$backend"
# Use the Collector's JSON encoding in tests so assertions do not depend on
# protobuf attribute order. Production export keeps its default encoding.
json_export() {
  sed -i '/^  otlp_http\/backend:/a\    encoding: json' "$dir/otelcol.yaml"
  pkill -HUP -x otelcol-contrib 2>/dev/null || true
}
# The test backend keeps structured OTLP JSON and HTTP headers.
cat >"$backend/server.js" <<'EOF'
const http = require("http"), fs = require("fs"), zlib = require("zlib");
let n = 0;
http.createServer((req, res) => {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    let body = Buffer.concat(chunks);
    if (req.headers["content-encoding"] === "gzip") body = zlib.gunzipSync(body);
    fs.writeFileSync(`${process.argv[2]}/req-${++n}`, JSON.stringify({ headers: req.headers, payload: JSON.parse(body.toString()) }));
    res.writeHead(200, { "content-type": "application/json" });
    res.end("{}");
  });
}).listen(14320, "127.0.0.1");
EOF
mkdir "$backend/out"
node "$backend/server.js" "$backend/out" &
server=$!

out=$(echo 'Bearer test-backend-key' | onbehalf telemetry on --export http://127.0.0.1:14320 2>&1)
check "telemetry on succeeds" test $? -eq 0
sed 's/^/        /' <<<"$out"
check "telemetry on tells that the Collector does not run yet" grep -q "the OTel Collector does not answer" <<<"$out"
json_export
check "the Collector configuration is valid" otelcol-contrib validate --config "$dir/otelcol.yaml"
check "the users cannot read the telemetry keys of the Collector" denied alice "cat $dir/htpasswd"
check "the users cannot read the authorization of the backend" denied alice "cat $dir/export-auth"
check "the users cannot read the pseudonym secret" denied alice "cat $dir/identity-salt"
salt_hash=$(sha256sum "$dir/identity-salt")
check "the telemetry key of alice is private" test "$(stat -c '%a %U' /home/alice/.config/onbehalf/telemetry.key)" = "600 alice"
check "alice has the telemetry plugin" \
  test "$(readlink /home/alice/.config/opencode/plugins/onbehalf-telemetry.js)" = /usr/local/lib/onbehalf/telemetry/opencode.js
check "alice is a user of the Collector" grep -q '^alice:' "$dir/htpasswd"

runuser -u otelcol-contrib -- otelcol-contrib --config "$dir/otelcol.yaml" >"$backend/collector.log" 2>&1 &
for _ in $(seq 1 30); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:4318/v1/traces)" != 401 ] || break
  sleep 1
done
out=$(onbehalf user add carol 2>&1)
check "user add gives carol a telemetry key" grep -q "has a personal telemetry key" <<<"$out"
check "carol is a user of the Collector after user add" grep -q '^carol:' "$dir/htpasswd"
out=$(onbehalf doctor 2>&1)
check "doctor: the Collector accepts telemetry only with a key" grep -q "accepts telemetry on port 4318, only with a key" <<<"$out"
cp -p "$dir/otelcol.yaml" "$backend/current.yaml"
sed -i '/^# onbehalf telemetry schema:/d' "$dir/otelcol.yaml"
stale_hash=$(sha256sum "$dir/otelcol.yaml")
out=$(onbehalf doctor 2>&1)
check "doctor warns when an upgrade leaves stale privacy configuration" grep -q 'telemetry configuration is outdated' <<<"$out"
check "doctor gives the explicit configuration migration step" grep -q 'existing backend authorization' <<<"$out"
check "doctor does not change the Collector configuration" test "$(sha256sum "$dir/otelcol.yaml")" = "$stale_hash"
mv "$backend/current.yaml" "$dir/otelcol.yaml"
out=$(onbehalf doctor --user alice 2>&1)
check "doctor: OpenCode of alice sends the tool calls" grep -q "OpenCode sends the tool calls" <<<"$out"

# A span that says that it is of alice, with the key of carol.
span='{"resourceSpans":[{"resource":{"attributes":[{"key":"user.name","value":{"stringValue":"alice"}}]},"scopeSpans":[{"spans":[{"traceId":"5b8efff798038103d269b633813fc60c","spanId":"eee19b7ec3c1b174","name":"onbehalf-spoof-test","kind":1,"startTimeUnixNano":"1","endTimeUnixNano":"2"}]}]}]}'
post() { # post USER KEYFILE: the HTTP status of one span
  as "$1" "curl -s -o /dev/null -w '%{http_code}' -u \"$2:\$(cat $3)\" -H 'content-type: application/json' --data '$span' http://127.0.0.1:4318/v1/traces"
}
check "the Collector refuses the name of alice with the key of carol" test "$(post carol alice /home/carol/.config/onbehalf/telemetry.key)" = 401
check "the Collector accepts the key of carol" test "$(post carol carol /home/carol/.config/onbehalf/telemetry.key)" = 200

# A runtime that ran before telemetry on gets the plugin at its next start.
onbehalf restart alice >/dev/null 2>&1
as alice "cd ~ && timeout 180 opencode run --auto -m onbehalf/agent-model 'RUN: echo onbehalf-telemetry-probe'" >/dev/null 2>&1
check "OpenCode of alice stops after the run" test $? -eq 0
# Keep substring checks for content exclusion; use decoded spans for behavior.
got() { grep -aqF -- "$1" "$backend"/out/req-* 2>/dev/null; }
exported_spans() {
  jq -s '[.[].payload.resourceSpans[].scopeSpans[].spans[] |
    .attributes = ((.attributes // []) | map({key, value: (.value | to_entries[0].value)}) | from_entries)]' "$backend"/out/req-* 2>/dev/null
}
for _ in $(seq 1 20); do
  ! got "execute_tool shell" || break
  sleep 1
done
check "the backend gets no raw shell command" bash -c '! grep -aq onbehalf-telemetry-probe "$@"' _ "$backend"/out/req-*
check "the backend gets the tool call as a GenAI span" got "execute_tool shell"
check "the backend gets the model steps" got "chat agent-model"
check "the backend gets the task of the prompt" got "invoke_agent"
check "the spans have the OpenCode session" got "session.id"
check "the Collector sets user.id on each span, for backends such as Langfuse" got "user.id"
check "the Collector sends the authorization of the backend" got '"authorization":"Bearer test-backend-key"'
# The fake model gives the text onbehalf-agent-done after a tool call.
check "the backend gets no model answer" bash -c '! grep -aq onbehalf-agent-done "$@"' _ "$backend"/out/req-*

# Real plugin output must reach the classifier with no private arguments.
as alice 'touch /tmp/onbehalf-telemetry-delete-test'
for command in 'ls /tmp' 'rm /tmp/onbehalf-telemetry-delete-test' 'false'; do
  as alice "cd ~ && timeout 180 opencode run --auto -m onbehalf/agent-model 'RUN: $command'" >/dev/null 2>&1
  check "the real shell telemetry run stops: $command" test $? -eq 0
done
shell_results() {
  exported_spans | jq -e '
    any(.[]; .name == "execute_tool shell" and .attributes["langfuse.observation.type"] == "TOOL" and
      .attributes["langfuse.observation.metadata.command_summary"] == "ls" and .attributes["tool.class"] == "read") and
    any(.[]; .name == "execute_tool shell" and .attributes["langfuse.observation.metadata.command_summary"] == "rm" and
      .attributes["tool.class"] == "write" and (.attributes["process.exit.code"] // -1 | tonumber) == 0) and
    any(.[]; .name == "execute_tool shell" and (.attributes["process.exit.code"] // -1 | tonumber) == 1 and .attributes["error.type"] == "exit_code")' >/dev/null
}
for _ in $(seq 1 20); do
  shell_results && break
  sleep 1
done
check "real plugin spans preserve read/write classes and shell failures" shell_results

# A real Code Mode run: concurrent calls have the same outer call ID.
cat >/home/alice/.config/opencode/plugins/telemetry-probe.js <<'EOF'
export default { id: "telemetry-probe", setup: async (ctx) => {
  await ctx.tool.transform((editor) => {
    editor.namespace({ name: "telemetry_test", description: "Synthetic telemetry checks" });
    editor.add({ name: "probe", description: "Return a synthetic result",
      input: { type: "object", properties: { delay: { type: "number" } }, required: ["delay"] },
      options: { namespace: "telemetry_test", codemode: true },
      execute: async ({ delay }) => {
        await new Promise((resolve) => setTimeout(resolve, delay));
        return { content: "PRIVATE_CODEMODE_OUTPUT" };
      } });
  });
} };
EOF
chown alice:alice /home/alice/.config/opencode/plugins/telemetry-probe.js
as alice "cd ~ && timeout 180 opencode run --auto -m onbehalf/agent-model 'RUN_CODE: return await Promise.all([tools.telemetry_test.probe({delay: 50}), tools.telemetry_test.probe({delay: 100})]);'" >/dev/null 2>&1
check "the real Code Mode run stops" test $? -eq 0
for _ in $(seq 1 20); do
  ! got "execute_tool telemetry_test_probe" || break
  sleep 1
done
codemode_results() {
  exported_spans | jq -e '
    [.[] | select(.name == "execute_tool telemetry_test_probe")] as $children |
    [.[] | select(.name == "execute_tool execute")] as $containers |
    $containers[0] as $container |
    [.[] | select(.traceId == $container.traceId and (.name | startswith("invoke_agent")))] as $tasks |
    ($children | length) == 2 and ($containers | length) == 1 and ($tasks | length) == 1 and
    ($tasks[0].attributes["langfuse.observation.metadata.tool_call_count"] | tonumber) == 2 and
    ($tasks[0].attributes["langfuse.observation.metadata.tool_failure_count"] | tonumber) == 0 and
    $container.attributes["langfuse.observation.type"] == "SPAN" and
    all($children[]; .parentSpanId == $container.spanId and .traceId == $container.traceId and
      .attributes["langfuse.observation.type"] == "TOOL" and
      .attributes["langfuse.observation.metadata.execution_observed"] == true and
      (.status.code == 1 or .status.code == "STATUS_CODE_OK") and
      (.endTimeUnixNano | tonumber) > (.startTimeUnixNano | tonumber)) and
    ($children[0].startTimeUnixNano | tonumber) < ($children[1].endTimeUnixNano | tonumber) and
    ($children[1].startTimeUnixNano | tonumber) < ($children[0].endTimeUnixNano | tonumber)' >/dev/null
}
for _ in $(seq 1 20); do
  codemode_results && break
  sleep 1
done
check "real Code Mode calls have exact counts, parent links, results and overlapping durations" codemode_results
check "the backend gets model first-token time" got "langfuse.observation.completion_start_time"
check "the backend gets no Code Mode result" bash -c '! grep -aq PRIVATE_CODEMODE_OUTPUT "$@"' _ "$backend"/out/req-*
rm /home/alice/.config/opencode/plugins/telemetry-probe.js
spoof=$(grep -al onbehalf-spoof-test "$backend"/out/req-* | head -1)
pseudonym=$(printf 'carol:%s' "$(cat "$dir/identity-salt")" | sha256sum | cut -d' ' -f1)
check "the Collector uses the pseudonym of carol, not either account name" \
  bash -c 'grep -aq "$2" "$1" && ! grep -aqE "carol|alice" "$1"' _ "${spoof:-/dev/null}" "$pseudonym"
if [ "$FAILED" != 0 ]; then
  echo "        the Collector log:"
  tail -20 "$backend/collector.log" | sed 's/^/        /'
fi

# The tool classes. The client gives the class read: the Collector replaces it.
tool_span() { # tool_span USER KEYFILE COMMAND: the HTTP status of one tool span
  local body
  body=$(jq -nc --arg c "$3" --arg t "$(openssl rand -hex 16)" --arg s "$(openssl rand -hex 8)" '{resourceSpans: [{resource: {attributes: [{key: "host.name", value: {stringValue: "PRIVATE_HOST"}}]},
    scopeSpans: [{spans: [{traceId: $t, spanId: $s, name: "execute_tool shell", kind: 1, startTimeUnixNano: "1", endTimeUnixNano: "2",
    attributes: [{key: "gen_ai.operation.name", value: {stringValue: "execute_tool"}}, {key: "gen_ai.tool.name", value: {stringValue: "shell"}},
      {key: "process.command_line", value: {stringValue: $c}}, {key: "tool.class", value: {stringValue: "read"}},
      {key: "private.input", value: {stringValue: "PRIVATE_ARGUMENT"}},
      {key: "gen_ai.tool.call.id", value: {stringValue: $s}}]}]}]}]}')
  TOOL_SPAN_ID=$(jq -r '.resourceSpans[0].scopeSpans[0].spans[0].spanId' <<<"$body")
  as "$1" "curl -s -o /dev/null -w '%{http_code}' -u \"$1:\$(cat $2)\" -H 'content-type: application/json' --data '$body' http://127.0.0.1:4318/v1/traces"
}
# Match the exact span's call ID and class, independent of attribute order.
class() {
  for _ in $(seq 1 20); do
    exported_spans | jq -e --arg id "$1" --arg class "$2" 'any(.[];
      .attributes["gen_ai.tool.call.id"] == $id and .attributes["tool.class"] == $class)' >/dev/null && return 0
    sleep 1
  done
  return 1
}
key=/home/carol/.config/onbehalf/telemetry.key
tool_span carol "$key" "kubectl delete pod web-1" >/dev/null
check "the Collector gives the class write to kubectl delete, not the class of the client" class "$TOOL_SPAN_ID" write
tool_span carol "$key" "kubectl get pods -A" >/dev/null
check "the Collector gives the class read to kubectl get" class "$TOOL_SPAN_ID" read
tool_span carol "$key" "make build" >/dev/null
check "the Collector gives the class unknown to a command without a rule" class "$TOOL_SPAN_ID" unknown
check "the class is also a metadata key for Langfuse" got "langfuse.observation.metadata.tool_class"

# An old client can still send a command. The Collector removes all of it.
script=$(printf 'python3 - <<EOF # onbehalf-script-test\ntoken = "onbehalf-secret-marker"\nrequest(url, method="DELETE")\nEOF')
tool_span carol "$key" "$script" >/dev/null
check "a script with an HTTP DELETE gets the class write" class "$TOOL_SPAN_ID" write
tool_span carol "$key" "command -v az kubectl" >/dev/null
check "command -v gets the class read" class "$TOOL_SPAN_ID" read
check "the backend gets no command, arguments or host name" bash -c '! grep -aqE "process.command_line|onbehalf-secret-marker|onbehalf-script-test|PRIVATE_" "$@"' _ "$backend"/out/req-*

stack=$(mktemp -d)
cp -R /src/test/stack/. "$stack"
mkdir "$stack/telemetry"
echo '{"rules": [{"class": "read", "command": "(?!x)"}]}' >"$stack/telemetry/classes.json"
out=$(onbehalf stack install "$stack" 2>&1)
check "stack install refuses a tool class pattern with lookaround" grep -q "no lookaround" <<<"$out"
echo '{"rules": [{"class": "write", "command": "\\bmake\\s+deploy\\b"}]}' >"$stack/telemetry/classes.json"
out=$(onbehalf stack install "$stack" 2>&1)
check "stack install gives the tool classes of the shared stack to the Collector" \
  grep -q "the Collector uses the tool classes of $ONBEHALF_STACK/current/telemetry/classes.json" <<<"$out"
json_export
sleep 2
tool_span carol "$key" "make deploy now" >/dev/null
check "the Collector uses the rules of the shared stack" class "$TOOL_SPAN_ID" write
tool_span carol "$key" "kubectl get nodes" >/dev/null
check "the default rules apply after the rules of the shared stack" class "$TOOL_SPAN_ID" read
check "the pseudonym secret stays stable after stack changes" test "$(sha256sum "$dir/identity-salt")" = "$salt_hash"
onbehalf stack install /src/test/stack >/dev/null 2>&1
rm -rf "$stack"

# A removed user: the Collector refuses the key.
cp /home/carol/.config/onbehalf/telemetry.key "$backend/carol.key"
chmod 0644 "$backend/carol.key"
onbehalf user remove carol >/dev/null 2>&1
sleep 2
check "the Collector refuses the key of carol after user remove" test "$(post alice carol "$backend/carol.key")" = 401

out=$(onbehalf telemetry off 2>&1)
check "telemetry off succeeds" test $? -eq 0
check "telemetry off removes the plugin of alice" test ! -e /home/alice/.config/opencode/plugins/onbehalf-telemetry.js
sleep 2
check "the Collector refuses the key of alice after telemetry off" test "$(post alice alice /home/alice/.config/onbehalf/telemetry.key)" = 401

pkill -x otelcol-contrib
kill "$server"
rm -rf "$backend"
exit $FAILED
