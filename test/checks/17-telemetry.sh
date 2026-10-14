#!/usr/bin/env bash
# onbehalf telemetry with OpenCode. The plugin sends a span for each tool
# call and each model step to the OTel Collector. The Collector accepts only
# the telemetry key of a user and sets user.name from it. A test backend on
# the host keeps what the Collector exports. Only a test host with the OTel
# Collector runs this check.
set -uo pipefail
. /src/test/lib.sh

if ! command -v otelcol-contrib >/dev/null; then
  echo "  skip  the OTel Collector is not installed on this test host"
  exit 0
fi

dir=/etc/onbehalf/telemetry
backend=$(mktemp -d)
chmod 0755 "$backend"
# The test backend: keep each request body (OTLP protobuf, unzipped) and its headers.
cat >"$backend/server.js" <<'EOF'
const http = require("http"), fs = require("fs"), zlib = require("zlib");
let n = 0;
http.createServer((req, res) => {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    let body = Buffer.concat(chunks);
    if (req.headers["content-encoding"] === "gzip") body = zlib.gunzipSync(body);
    fs.writeFileSync(`${process.argv[2]}/req-${++n}`, JSON.stringify(req.headers) + "\n" + body.toString("latin1"));
    res.writeHead(200, { "content-type": "application/x-protobuf" });
    res.end();
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
check "the Collector configuration is valid" otelcol-contrib validate --config "$dir/otelcol.yaml"
check "the users cannot read the telemetry keys of the Collector" denied alice "cat $dir/htpasswd"
check "the users cannot read the authorization of the backend" denied alice "cat $dir/export-auth"
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
# The backend keeps OTLP protobuf: search the files as text with grep -a.
got() { grep -aqF -- "$1" "$backend"/out/req-* 2>/dev/null; }
for _ in $(seq 1 20); do
  ! got onbehalf-telemetry-probe || break
  sleep 1
done
check "the backend gets the tool call of alice, with its command" got "echo onbehalf-telemetry-probe"
check "the backend gets the tool call as a GenAI span" got "execute_tool shell"
check "the backend gets the model steps" got "chat agent-model"
check "the backend gets the task of the prompt" got "invoke_agent"
check "the spans have the OpenCode session" got "session.id"
check "the Collector sets user.id on each span, for backends such as Langfuse" got "user.id"
check "the Collector sends the authorization of the backend" got '"authorization":"Bearer test-backend-key"'
# The fake model gives the text onbehalf-agent-done after a tool call.
check "the backend gets no model answer" bash -c '! grep -aq onbehalf-agent-done "$@"' _ "$backend"/out/req-*
spoof=$(grep -al onbehalf-spoof-test "$backend"/out/req-* | head -1)
check "the span that carol sent is of carol, not alice" \
  bash -c 'grep -aq carol "$1" && ! grep -aq alice "$1"' _ "${spoof:-/dev/null}"
if [ "$FAILED" != 0 ]; then
  echo "        the Collector log:"
  tail -20 "$backend/collector.log" | sed 's/^/        /'
fi

# The tool classes. The client gives the class read: the Collector replaces it.
tool_span() { # tool_span USER KEYFILE COMMAND: the HTTP status of one tool span
  local body
  body=$(jq -nc --arg c "$3" --arg t "$(openssl rand -hex 16)" --arg s "$(openssl rand -hex 8)" '{resourceSpans: [{resource: {},
    scopeSpans: [{spans: [{traceId: $t, spanId: $s, name: "execute_tool shell", kind: 1, startTimeUnixNano: "1", endTimeUnixNano: "2",
    attributes: [{key: "gen_ai.operation.name", value: {stringValue: "execute_tool"}}, {key: "gen_ai.tool.name", value: {stringValue: "shell"}},
      {key: "process.command_line", value: {stringValue: $c}}, {key: "tool.class", value: {stringValue: "read"}}]}]}]}]}')
  as "$1" "curl -s -o /dev/null -w '%{http_code}' -u \"$1:\$(cat $2)\" -H 'content-type: application/json' --data '$body' http://127.0.0.1:4318/v1/traces"
}
# class COMMAND CLASS: the backend got the command with that class. The
# protobuf has no line ends, so the check searches the bytes after the command.
class() {
  for _ in $(seq 1 20); do
    cat "$backend"/out/req-* 2>/dev/null | tr '\n\0' '  ' | grep -aqP "\\Q$1\\E.{0,400}?tool\\.class.{1,8}$2" && return 0
    sleep 1
  done
  return 1
}
key=/home/carol/.config/onbehalf/telemetry.key
for c in "kubectl delete pod web-1" "kubectl get pods -A" "make build"; do tool_span carol "$key" "$c" >/dev/null; done
check "the Collector gives the class write to kubectl delete, not the class of the client" class "kubectl delete pod web-1" write
check "the Collector gives the class read to kubectl get" class "kubectl get pods -A" read
check "the Collector gives the class unknown to a command without a rule" class "make build" unknown
check "the class is also a metadata key for Langfuse" got "langfuse.observation.metadata.tool_class"

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
sleep 2
tool_span carol "$key" "make deploy now" >/dev/null
check "the Collector uses the rules of the shared stack" class "make deploy now" write
tool_span carol "$key" "kubectl get nodes" >/dev/null
check "the default rules apply after the rules of the shared stack" class "kubectl get nodes" read
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
