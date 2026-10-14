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

async function boot(events, responses = []) {
  const requests = [], warnings = [];
  let timer, clock = 1000, active = 0, maxActive = 0;
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
  const cleanup = module.namespace.default.setup({
    app: { version: "2.0.26" },
    event: { subscribe: async function* () { for (const e of events) yield e; } },
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
assert.ok(recorded.some((s) => attrs(s)["process.command_line"] === "echo safe-probe"));
assert.ok(recorded.some((s) => attrs(s)["process.command_line"] === "[redacted]"));
assert.ok(recorded.some((s) => s.status.message === "permission_denied"));
assert.doesNotMatch(JSON.stringify(sample.requests), /PRIVATE_|TEST_ONLY_KEY/);

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
