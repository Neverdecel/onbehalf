// Run the actual plugin with synthetic events and no host credentials or network.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as crypto from "node:crypto";
import { SourceTextModule, SyntheticModule, createContext } from "node:vm";

const source = readFileSync(new URL("../../lib/onbehalf/telemetry/opencode.js", import.meta.url), "utf8");
const turn = () => new Promise((resolve) => setImmediate(resolve));
const event = (type, data = {}) => ({ type, data: { sessionID: "session-test", ...data }, created: 1000 });
const start = () => event("session.execution.started");
const end = () => event("session.execution.succeeded");
const stepStart = () => event("session.step.started", { assistantMessageID: "message-test", agent: "build", model: { id: "test-model", providerID: "test" } });
const stepEnd = () => event("session.step.ended", { assistantMessageID: "message-test", tokens: { input: 3, output: 5, reasoning: 7, cache: { read: 11, write: 13 } }, finish: "stop" });
const tool = (id, name, input, terminal = "session.tool.success", extra = {}) => [
  event("session.tool.input.started", { id, name }),
  event("session.tool.called", { id, input }),
  event(terminal, { id, content: [{ text: "PRIVATE_TOOL_OUTPUT" }], ...extra }),
];
const ok = () => ({ ok: true, json: async () => ({}) });

async function boot(events, responses = [], hookCalls = []) {
  const requests = [], warnings = [];
  let timer, clock = 1000, active = 0, maxActive = 0;
  const hooks = {};
  const context = createContext({
    URL, Buffer, AbortController, AbortSignal,
    Date: class extends Date { static now() { return clock; } },
    setInterval: (fn) => { timer = fn; return { unref() {} }; },
    clearInterval() {},
    console: { warn: (...args) => warnings.push(args) },
    fetch: async (_url, request) => {
      requests.push(JSON.parse(request.body));
      active++;
      maxActive = Math.max(maxActive, active);
      try { return await (responses.shift() ?? ok)(); }
      finally { active--; }
    },
  });
  const module = new SourceTextModule(source, {
    context,
    initializeImportMeta: (meta) => { meta.url = new URL("../../lib/onbehalf/telemetry/opencode.js", import.meta.url).href; },
  });
  const builtins = {
    "node:fs": {
      readFileSync: (path) => {
        const name = String(path);
        if (name.endsWith("telemetry.json")) return '{"url":"http://collector.test"}';
        if (name.endsWith("telemetry.key")) return "TEST_ONLY_KEY";
        if (name.endsWith("VERSION")) return "0.2.0";
        return source;
      },
      realpathSync: () => "/opt/onbehalf/stack/releases/abcdef012345",
    },
    "node:os": { homedir: () => "/home/alice", hostname: () => "test-host", userInfo: () => ({ username: "alice" }) },
    "node:crypto": crypto,
  };
  await module.link((name) => {
    const exports = builtins[name];
    return new SyntheticModule(Object.keys(exports), function () {
      for (const [key, value] of Object.entries(exports)) this.setExport(key, value);
    }, { context });
  });
  await module.evaluate();
  const cleanup = await module.namespace.default.setup({
    app: { version: "2.0.26" },
    tool: { hook: async (name, callback) => { hooks[name] = callback; return { dispose: async () => { delete hooks[name]; } }; } },
    event: { subscribe: async function* () {
      for (const e of events) {
        if (e.hook) {
          clock = e.created;
          await hooks[e.hook](e.data);
        } else yield e;
      }
      for (const call of hookCalls) await hooks[call.hook](call.data);
    } },
  });
  await turn();
  return {
    requests, warnings, cleanup,
    tick: async () => { clock += 20000; timer(); await turn(); },
    maxActive: () => maxActive,
  };
}
const spans = (request) => request.resourceSpans[0].scopeSpans[0].spans;
const attrs = (span) => Object.fromEntries(span.attributes.map(({ key, value }) => [key, Object.values(value)[0]]));

const sample = await boot([
  start(), stepStart(), stepEnd(),
  ...tool("skill-test", "skill", { id: "test-skill", prompt: "PRIVATE_PROMPT" }),
  event("session.skill.activated", { name: "test-skill", text: "PRIVATE_SKILL_TEXT" }),
  ...tool("shell-test", "shell", { command: "echo safe-probe" }, undefined, { metadata: { exit: 0 } }),
  ...tool("credential-test", "shell", { command: "SERVICE_API_TOKEN=PRIVATE_CREDENTIAL curl https://example.test" }),
  ...tool("error-test", "read", {}, "session.tool.failed", { error: { type: "tool.execution", status: 403, message: "PRIVATE_ERROR_TEXT" } }),
  end(),
]);
await sample.cleanup();
const recorded = sample.requests.flatMap(spans);
assert.equal(recorded.length, 7);
assert.equal(new Set(recorded.map((s) => s.traceId)).size, 1);
const root = recorded.find((s) => !s.parentSpanId);
for (const s of recorded) {
  const a = attrs(s);
  assert.equal(a["langfuse.release"], "abcdef012345");
  assert.match(a["langfuse.version"], /^[a-f0-9]{12}$/);
  assert.equal(a["langfuse.trace.metadata.harness_version"], "2.0.26");
  if (s !== root) assert.equal(s.parentSpanId, root.spanId);
}
const generation = attrs(recorded.find((s) => s.name === "chat test-model"));
assert.equal(generation["gen_ai.usage.input_tokens"], 27);
assert.equal(generation["gen_ai.usage.output_tokens"], 12);
assert.equal(generation["gen_ai.usage.cache_read.input_tokens"], 11);
assert.equal(generation["gen_ai.usage.cache_creation.input_tokens"], 13);
assert.equal(generation["gen_ai.usage.reasoning.output_tokens"], 7);
assert.equal(attrs(root)["langfuse.observation.metadata.task_result"], "completed");
assert.ok(recorded.some((s) => attrs(s)["langfuse.observation.metadata.skill_name"] === "test-skill"));
assert.ok(recorded.some((s) => attrs(s)["langfuse.observation.metadata.command_summary"] === "unknown"));
assert.ok(recorded.some((s) => attrs(s)["process.command_line"] === "echo"));
assert.ok(recorded.some((s) => s.status.message === "permission_denied"));
assert.doesNotMatch(JSON.stringify(sample.requests), /PRIVATE_|TEST_ONLY_KEY/);

// Real hooks carry the same input object before/after. Code Mode reuses the
// outer ID, but different input objects permit parallel calls to one tool.
const outerInput = { code: "PRIVATE_CODE" }, firstInput = { query: "PRIVATE_QUERY_1" }, secondInput = { query: "PRIVATE_QUERY_2" };
const hook = (name, tool, input, created, extra = {}) => ({ hook: `execute.${name}`, created, data: { sessionID: "session-test", id: "outer", tool, input, ...extra } });
const timing = await boot([
  start(),
  { ...stepStart(), data: { ...stepStart().data, started: 1010 }, created: 1020 },
  { ...event("session.reasoning.delta", { assistantMessageID: "message-test", delta: "PRIVATE_REASONING" }), created: 1100 },
  { ...event("session.text.delta", { assistantMessageID: "message-test", delta: "" }), created: 1120 },
  { ...event("session.text.delta", { assistantMessageID: "message-test", delta: "PRIVATE_ANSWER" }), created: 1200 },
  { ...event("session.step.streamed", { assistantMessageID: "message-test" }), created: 1250 },
  event("session.tool.input.started", { id: "outer", name: "execute" }),
  hook("before", "execute", outerInput, 1300),
  hook("before", "datadog_search_logs", firstInput, 1400),
  hook("before", "datadog_search_logs", secondInput, 1450),
  hook("after", "datadog_search_logs", secondInput, 1500, { status: "error", error: { status: 429, message: "PRIVATE_ERROR" } }),
  hook("after", "datadog_search_logs", firstInput, 1600, { status: "completed", result: { content: "PRIVATE_OUTPUT" } }),
  hook("after", "execute", outerInput, 1700, { status: "completed", result: {} }),
  event("session.tool.success", { id: "outer" }),
  { ...event("session.retry.scheduled", { assistantMessageID: "message-test", attempt: 2, error: { status: 503, message: "PRIVATE_ERROR" } }), created: 1800 },
  { ...stepEnd(), created: 1900 },
  { ...end(), created: 2000 },
]);
await timing.cleanup();
const timed = timing.requests.flatMap(spans);
const wrapper = timed.find((s) => s.name === "execute_tool execute");
const inner = timed.filter((s) => s.name === "execute_tool datadog_search_logs");
assert.equal(inner.length, 2);
for (const s of inner) assert.equal(s.parentSpanId, wrapper.spanId);
assert.equal(inner[0].endTimeUnixNano - inner[0].startTimeUnixNano, 50000000);
assert.equal(inner[1].endTimeUnixNano - inner[1].startTimeUnixNano, 200000000);
assert.equal(inner[0].status.message, "rate_limit");
assert.equal(timed.filter((s) => s.name === wrapper.name).length, 1);
const timedModel = timed.find((s) => s.name === "chat test-model");
assert.equal(timedModel.endTimeUnixNano, "1250000000");
assert.equal(attrs(timedModel)["langfuse.observation.metadata.time_to_first_token_ms"], 90);
assert.equal(attrs(timedModel)["langfuse.observation.metadata.time_to_first_text_ms"], 190);
const timedRoot = timed.find((s) => s.name.startsWith("invoke_agent"));
assert.equal(attrs(timedRoot)["langfuse.observation.metadata.time_to_first_text_ms"], 200);
assert.equal(attrs(timedRoot)["langfuse.observation.metadata.tool_call_count"], 2);
assert.equal(attrs(timedRoot)["langfuse.observation.metadata.tool_failure_count"], 1);
assert.equal(attrs(timedRoot)["langfuse.observation.metadata.model_step_count"], 1);
assert.equal(attrs(timedRoot)["langfuse.observation.metadata.retry_count"], 1);
assert.doesNotMatch(JSON.stringify(timing.requests), /PRIVATE_/);

const unfinishedInput = { code: "PRIVATE_UNFINISHED_CODE" };
const interrupted = await boot([start(),
  event("session.tool.input.started", { id: "outer", name: "execute" }),
  hook("before", "execute", unfinishedInput, 1200),
  { ...event("session.execution.interrupted"), created: 1400 }]);
await interrupted.cleanup();
assert.equal(interrupted.requests.flatMap(spans).find((s) => s.name === "execute_tool execute").status.message, "interrupted");
assert.doesNotMatch(JSON.stringify(interrupted.requests), /PRIVATE_/);

const transformed = await boot([start(),
  event("session.tool.input.started", { id: "outer", name: "shell" }),
  hook("before", "shell", { command: "kubectl get pods PRIVATE_NAMESPACE" }, 1200),
  hook("after", "shell", { command: "kubectl delete pod PRIVATE_RESOURCE" }, 1400, { status: "completed", result: {} }), end()]);
await transformed.cleanup();
assert.equal(attrs(transformed.requests.flatMap(spans).find((s) => s.name === "execute_tool shell"))["langfuse.observation.metadata.command_summary"], "kubectl delete");
assert.doesNotMatch(JSON.stringify(transformed.requests), /PRIVATE_/);

const longName = "a".repeat(65), longInput = {};
const longTool = await boot([start(),
  event("session.tool.input.started", { id: "outer", name: longName }),
  hook("before", longName, longInput, 1200),
  hook("after", longName, longInput, 1400, { status: "completed", result: {} }),
  event("session.tool.success", { id: "outer" }), end()]);
await longTool.cleanup();
const longSpans = longTool.requests.flatMap(spans);
assert.equal(longSpans.filter(s => s.name === "execute_tool unknown").length, 1);
assert.equal(attrs(longSpans.find(s => s.name.startsWith("invoke_agent")))["langfuse.observation.metadata.tool_call_count"], 1);
assert.doesNotMatch(JSON.stringify(longTool.requests), new RegExp(longName));

// Input replacement during parallel calls must not invent tool latency or failures.
const ambiguous = await boot([start(),
  event("session.tool.input.started", { id: "outer", name: "execute" }),
  hook("before", "execute", outerInput, 1200),
  hook("before", "datadog_search_logs", firstInput, 1300),
  hook("before", "datadog_search_logs", secondInput, 1350),
  hook("after", "datadog_search_logs", { query: "PRIVATE_REPLACED_2" }, 1400, { status: "completed", result: {} }),
  hook("after", "datadog_search_logs", { query: "PRIVATE_REPLACED_1" }, 1500, { status: "completed", result: {} }),
  hook("after", "execute", outerInput, 1600, { status: "completed", result: {} }), end()]);
await ambiguous.cleanup();
const ambiguousSpans = ambiguous.requests.flatMap(spans);
const ambiguousTools = ambiguousSpans.filter(s => s.name === "execute_tool datadog_search_logs");
assert.equal(ambiguousTools.length, 2);
for (const s of ambiguousTools) {
  assert.equal(attrs(s)["langfuse.observation.type"], "EVENT");
  assert.equal(attrs(s)["langfuse.observation.metadata.execution_observed"], false);
  assert.equal(attrs(s)["langfuse.observation.metadata.execution_match"], "ambiguous");
  assert.equal(s.startTimeUnixNano, s.endTimeUnixNano);
  assert.equal(s.status.code, 1);
}
const ambiguousRoot = attrs(ambiguousSpans.find(s => s.name.startsWith("invoke_agent")));
assert.equal(ambiguousRoot["langfuse.observation.metadata.tool_call_count"], 2);
assert.equal(ambiguousRoot["langfuse.observation.metadata.tool_failure_count"], 0);
assert.equal(ambiguousRoot["langfuse.observation.metadata.tool_unobserved_count"], 2);
assert.doesNotMatch(JSON.stringify(ambiguous.requests), /PRIVATE_/);

for (const terminal of ["session.execution.interrupted", "session.execution.succeeded"]) {
  const missing = await boot([start(), event("session.tool.input.started", { id: "outer", name: "shell" }),
    hook("before", "shell", { command: "ls /tmp" }, 1200), { ...event(terminal), created: 1400 }]);
  await missing.cleanup();
  const missingSpans = missing.requests.flatMap(spans);
  const counters = attrs(missingSpans.find(s => s.name.startsWith("invoke_agent")));
  assert.equal(counters["langfuse.observation.metadata.tool_failure_count"], 0);
  assert.equal(counters["langfuse.observation.metadata.tool_unobserved_count"], 1);
  assert.equal(counters["langfuse.observation.metadata.tool_interruption_count"], terminal.endsWith("interrupted") ? 1 : 0);
  assert.equal(attrs(missingSpans.find(s => s.name === "execute_tool shell"))["langfuse.observation.type"], "EVENT");
}

const secretSkill = await boot([start(), ...tool("bad-skill", "skill", { id: "PRIVATE_SECRET_ARGUMENT" }, "session.tool.failed"), end()]);
await secretSkill.cleanup();
assert.doesNotMatch(JSON.stringify(secretSkill.requests), /PRIVATE_SECRET_ARGUMENT|skill_name/);
const secretTool = await boot([start(), ...tool("bad-tool", "PRIVATE_UNKNOWN_TOOL_ARGUMENT", {}, "session.tool.failed"), end()]);
await secretTool.cleanup();
assert.doesNotMatch(JSON.stringify(secretTool.requests), /PRIVATE_UNKNOWN_TOOL_ARGUMENT/);
const renamedInput = {};
const renamedTool = await boot([start(), event("session.tool.input.started", { id: "outer", name: "PRIVATE_TOOL_ALIAS" }),
  hook("before", "PRIVATE_TOOL_ALIAS", renamedInput, 1200),
  hook("after", "read", renamedInput, 1400, { status: "completed", result: {} }), end()]);
await renamedTool.cleanup();
assert.ok(renamedTool.requests.flatMap(spans).some(s => s.name === "execute_tool read"));
assert.doesNotMatch(JSON.stringify(renamedTool.requests), /PRIVATE_TOOL_ALIAS/);

const abortedInput = {};
const aborted = await boot([start(), event("session.tool.input.started", { id: "outer", name: "read" }),
  hook("before", "read", abortedInput, 1200),
  hook("after", "read", abortedInput, 1400, { status: "error", error: { type: "AbortError", message: "PRIVATE_ABORT" } }),
  event("session.execution.interrupted")]);
await aborted.cleanup();
const abortCounts = attrs(aborted.requests.flatMap(spans).find(s => s.name.startsWith("invoke_agent")));
assert.equal(abortCounts["langfuse.observation.metadata.tool_failure_count"], 0);
assert.equal(abortCounts["langfuse.observation.metadata.tool_interruption_count"], 1);

const commands = await boot([start(),
  ...tool("known", "shell", { command: "kubectl get pods --namespace PRIVATE_NAMESPACE" }),
  ...tool("compound", "shell", { command: "kubectl get pods && kubectl delete pods PRIVATE_RESOURCE" }),
  ...tool("script", "shell", { command: "python3 - <<EOF\nPRIVATE_SCRIPT\nEOF" }),
  ...tool("prefix", "shell", { command: "kubectl get-private-write PRIVATE_TARGET" }),
  ...tool("rtk", "shell", { command: "rtk git status --short PRIVATE_PATH" }), end()]);
await commands.cleanup();
const summaries = commands.requests.flatMap(spans).map((s) => attrs(s)["langfuse.observation.metadata.command_summary"]).filter(Boolean);
assert.deepEqual(summaries, ["kubectl get", "unknown", "unknown", "unknown", "git status"]);
assert.doesNotMatch(JSON.stringify(commands.requests), /PRIVATE_/);

const coverage = [
  ["rm -rf PRIVATE_PATH", "rm"], ["docker run PRIVATE_IMAGE", "docker run"],
  ["gh pr merge PRIVATE_NUMBER", "gh pr merge"], ["aws s3 rm s3://PRIVATE_BUCKET/PRIVATE_KEY", "aws s3 rm"],
  ["ls PRIVATE_PATH", "ls"], ["command -v PRIVATE_BINARY", "command -v"],
  ["gh api PRIVATE_URL -X DELETE", "unknown"], ["find PRIVATE_PATH -delete", "unknown"],
  ["git diff --output PRIVATE_PATH", "unknown"], ["git branch --delete PRIVATE_BRANCH", "unknown"],
];
const labelTest = await boot([start(), ...coverage.flatMap(([command], index) => tool(`coverage-${index}`, "shell", { command })), end()]);
await labelTest.cleanup();
assert.deepEqual(labelTest.requests.flatMap(spans).filter(s => s.name === "execute_tool shell").map(s => attrs(s)["langfuse.observation.metadata.command_summary"]), coverage.map(([, label]) => label));
assert.doesNotMatch(JSON.stringify(labelTest.requests), /PRIVATE_/);

// A failed HTTP response or network request retains the same spans for retry.
for (const failure of [() => ({ ok: false }), () => { throw new Error("PRIVATE_NETWORK_ERROR"); }]) {
  const retry = await boot([start(), end()], [failure]);
  await retry.tick();
  assert.equal(retry.requests.length, 2);
  assert.equal(spans(retry.requests[0])[0].spanId, spans(retry.requests[1])[0].spanId);
  assert.equal(attrs(spans(retry.requests[1])[0])["langfuse.observation.metadata.telemetry_export_failures"], 1);
  assert.equal(retry.maxActive(), 1);
  await retry.cleanup();
}

// Partial acceptance is not retried, and rejection is reported without server content.
const partial = await boot([start(), end()], [() => ({ ok: true, json: async () => ({ partialSuccess: { rejectedSpans: "1", errorMessage: "PRIVATE_SERVER_ERROR" } }) })]);
await partial.cleanup();
assert.equal(partial.requests.length, 1);
assert.match(JSON.stringify(partial.warnings), /rejected/);
assert.doesNotMatch(JSON.stringify(partial.warnings), /PRIVATE_/);

// A long outage does not permit unlimited requests, queue growth or shutdown waits.
const flood = Array.from({ length: 1200 }, () => event("session.skill.activated", { name: "test-skill" }));
const outage = await boot(flood, Array.from({ length: 10 }, () => () => ({ ok: false })));
await outage.cleanup();
assert.ok(outage.requests.length <= 4);
assert.ok(outage.requests.every((r) => spans(r).length <= 200));
assert.equal(outage.maxActive(), 1);
assert.match(JSON.stringify(outage.warnings), /droppedSpans/);
console.log("telemetry plugin: version, token, privacy, error and export checks pass");
