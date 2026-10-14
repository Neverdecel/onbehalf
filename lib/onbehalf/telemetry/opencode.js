// onbehalf telemetry plugin for OpenCode 2.x. OpenCode exports no tool
// data to OpenTelemetry, so this plugin reads the session events and sends
// spans to the local OTel Collector of the host: one trace for each task
// (a prompt), with one span for each model step and each tool call. The
// spans use the OTel GenAI conventions, and session.id for the session.
//
// The plugin sends the command of a shell tool call, but never a prompt, a
// model answer or a tool output. It authenticates with the personal
// telemetry key of the user. The Collector sets user.name from that key, so
// a user cannot send spans as a different user.
//
// The plugin does nothing if telemetry is off or the user has no key.
// Telemetry must never stop the runtime: each error is ignored.
import { readFileSync, realpathSync } from "node:fs";
import { createHash, randomBytes } from "node:crypto";
import { homedir, hostname, userInfo } from "node:os";

const CONFIG = "/etc/onbehalf/telemetry.json";
const FLUSH_MS = 5000;
const MAX_BATCH = 200;
const MAX_QUEUE = 1000;
const MAX_ATTEMPTS = 3;

const read = (file) => {
  try {
    return readFileSync(file, "utf8").trim();
  } catch {
    return "";
  }
};

const value = (v) =>
  typeof v === "number" && Number.isInteger(v) ? { intValue: v }
  : typeof v === "number" ? { doubleValue: v }
  : typeof v === "boolean" ? { boolValue: v }
  : Array.isArray(v) ? { arrayValue: { values: v.map(value) } }
  : { stringValue: String(v) };

const attributes = (obj) =>
  Object.entries(obj)
    .filter(([, v]) => v !== undefined && v !== null && v !== "")
    .map(([key, v]) => ({ key, value: value(v) }));

// One trace for each task: a prompt and the model steps and tool calls that
// answer it. A span outside a task gets one trace for its session.
const sessionTrace = (session) => createHash("sha256").update(String(session)).digest("hex").slice(0, 32);
const id = (bytes) => randomBytes(bytes).toString("hex");
const nanos = (ms) => `${BigInt(Math.round(ms)) * 1000000n}`;
const pluginVersion = createHash("sha256").update(read(new URL(import.meta.url))).digest("hex").slice(0, 12);
const safeName = (name) => typeof name === "string" && /^[a-z0-9][a-z0-9._-]{0,63}$/i.test(name) ? name : undefined;
// Suppress the whole command when common credential forms occur; do not export their values.
// shortcut: unmarked secrets can pass, use structured command export for a secrecy guarantee.
const sensitiveCommand = (command) => /password|passwd|token|secret|api[_-]?key|authorization|bearer|basic|:\/\/[^\s/]+:[^\s/]+@|\bsk-[a-z0-9_-]{16,}|\bcurl\b.*(?:\s-u\s|--user[ =])|\bsqlcmd\b.*\s-P\s/i.test(command);
const errorCategory = (error, fallback) => {
  if (error?.status === 401) return "authentication";
  if (error?.status === 403) return "permission_denied";
  if (error?.status === 404) return "not_found";
  if (error?.status === 429) return "rate_limit";
  if (error?.status >= 500 && error?.status <= 599) return "service_error";
  const type = typeof error?.type === "string" ? error.type : "";
  if (/timeout/i.test(type)) return "timeout";
  if (/not[-_.]?found/i.test(type)) return "not_found";
  if (/permission|forbidden|denied/i.test(type)) return "permission_denied";
  if (/authentication|unauthorized/i.test(type)) return "authentication";
  return fallback;
};

export default {
  id: "onbehalf-telemetry",
  setup: (ctx) => {
    let url, key;
    try {
      url = JSON.parse(read(CONFIG)).url;
    } catch {
      return;
    }
    key = read(`${homedir()}/.config/onbehalf/telemetry.key`);
    if (!url || !key) return;
    const auth = "Basic " + Buffer.from(`${userInfo().username}:${key}`).toString("base64");
    let stackID;
    try {
      // Capture the stack at plugin load, not a newer stack that the runtime has not loaded.
      const path = realpathSync("/opt/onbehalf/stack/current");
      stackID = /\/releases\/([a-f0-9]{12})$/.exec(path)?.[1];
    } catch { /* A runtime without a shared stack has no stack ID. */ }
    const versions = {
      "langfuse.release": stackID,
      "langfuse.version": pluginVersion,
      "langfuse.trace.metadata.stack_id": stackID,
      "langfuse.trace.metadata.telemetry_version": pluginVersion,
      "langfuse.trace.metadata.harness_version": ctx.app?.version,
      "langfuse.trace.metadata.onbehalf_version": read(new URL("../VERSION", import.meta.url)),
    };
    const resource = {
      attributes: attributes({
        "service.name": "opencode",
        "service.version": ctx.app?.version,
        "host.name": hostname(),
        "onbehalf.harness": "opencode",
      }),
    };

    let spans = [];
    const tools = new Map();
    const steps = new Map();
    const tasks = new Map();
    let sending, attempts = 0, retryAfter = 0, batchSize = 0;
    let exportFailures = 0, droppedSpans = 0, eventErrors = 0;

    const flush = (force = false) => {
      if (sending) return sending;
      if (spans.length === 0 || (!force && Date.now() < retryAfter)) return Promise.resolve();
      batchSize ||= Math.min(spans.length, MAX_BATCH);
      const batch = spans.slice(0, batchSize).map((s) => ({ ...s, attributes: [...s.attributes, ...attributes({
        "langfuse.observation.metadata.telemetry_export_failures": exportFailures,
        "langfuse.observation.metadata.telemetry_dropped_spans": droppedSpans,
        "langfuse.observation.metadata.telemetry_event_errors": eventErrors,
      })] }));
      sending = (async () => {
        try {
          const response = await fetch(`${url.replace(/\/$/, "")}/v1/traces`, {
            method: "POST",
            headers: { "content-type": "application/json", authorization: auth },
            body: JSON.stringify({ resourceSpans: [{ resource, scopeSpans: [{ scope: { name: "onbehalf" }, spans: batch }] }] }),
            signal: AbortSignal.timeout(5000),
          });
          if (!response.ok) throw new Error("export_failed");
          const result = await response.json().catch(() => ({}));
          const rejected = Number(result?.partialSuccess?.rejectedSpans ?? 0);
          // OTLP partial acceptance must not be retried: accepted spans would be duplicated.
          if (Number.isFinite(rejected) && rejected > 0) {
            droppedSpans += Math.min(batch.length, rejected);
            console.warn("onbehalf telemetry: Collector rejected spans", { rejected });
          }
          spans.splice(0, batch.length);
          batchSize = 0;
          attempts = 0;
          retryAfter = 0;
        } catch {
          exportFailures++;
          attempts++;
          retryAfter = Date.now() + FLUSH_MS * 2 ** (attempts - 1);
          if (attempts >= MAX_ATTEMPTS) {
            spans.splice(0, batch.length);
            batchSize = 0;
            droppedSpans += batch.length;
            attempts = 0;
          }
          console.warn("onbehalf telemetry: export failed", { exportFailures, droppedSpans });
        }
      })().finally(() => { sending = undefined; });
      return sending;
    };

    // A span of a task is a child of the task span. The task span is the root.
    const span = (session, name, kind, start, end, attrs, error, root) => {
      const task = tasks.get(session);
      if (spans.length >= MAX_QUEUE) {
        droppedSpans++;
        console.warn("onbehalf telemetry: queue full", { droppedSpans });
        return;
      }
      spans.push({
        traceId: root?.traceId ?? task?.traceId ?? sessionTrace(session),
        spanId: root?.spanId ?? id(8),
        parentSpanId: root ? undefined : task?.spanId,
        name,
        kind,
        startTimeUnixNano: nanos(start),
        endTimeUnixNano: nanos(end),
        attributes: attributes({ ...versions, "session.id": session, "gen_ai.conversation.id": session, ...attrs }),
        status: error ? { code: 2, message: error } : { code: 1 },
      });
      if (spans.length >= MAX_BATCH) void flush();
    };

    const tool = (e, error) => {
      const t = tools.get(e.data.id);
      if (!t) return;
      tools.delete(e.data.id);
      const exit = e.data.metadata?.exit;
      // A shell command that ends with an exit code other than 0 failed.
      const failed = error ? errorCategory(e.data.error, error)
        : exit === 124 ? "timeout" : exit === 127 ? "command_not_found"
        : typeof exit === "number" && exit !== 0 ? "exit_code" : undefined;
      const command = typeof t.input?.command === "string" ? t.input.command : undefined;
      const redacted = command !== undefined && sensitiveCommand(command);
      span(t.session, `execute_tool ${t.name}`, 1, t.start, e.created, {
        "gen_ai.operation.name": "execute_tool",
        "gen_ai.tool.name": t.name,
        "gen_ai.tool.type": "function",
        "gen_ai.tool.call.id": e.data.id,
        "process.command_line": redacted ? "[redacted]" : command,
        "onbehalf.command.redacted": redacted,
        "langfuse.observation.metadata.skill_name": t.name === "skill" ? safeName(t.input?.id ?? t.input?.name) : undefined,
        "process.exit.code": typeof exit === "number" ? exit : undefined,
        "error.type": failed,
      }, failed);
    };

    const step = (e, error) => {
      const s = steps.get(e.data.assistantMessageID);
      if (!s) return;
      steps.delete(e.data.assistantMessageID);
      const tokens = e.data.tokens ?? {};
      // OpenCode categories are disjoint; OTel input/output totals include cache/reasoning.
      const input = tokens.input === undefined ? undefined : tokens.input + (tokens.cache?.read ?? 0) + (tokens.cache?.write ?? 0);
      const output = tokens.output === undefined ? undefined : tokens.output + (tokens.reasoning ?? 0);
      const failed = error ? errorCategory(e.data.error, error) : undefined;
      span(e.data.sessionID, `chat ${s.model}`, 3, s.start, e.created, {
        "gen_ai.operation.name": "chat",
        "gen_ai.provider.name": s.provider,
        "gen_ai.request.model": s.model,
        "gen_ai.response.finish_reasons": e.data.finish ? [e.data.finish] : undefined,
        "gen_ai.usage.input_tokens": input,
        "gen_ai.usage.output_tokens": output,
        "gen_ai.usage.cache_read.input_tokens": tokens.cache?.read,
        "gen_ai.usage.cache_creation.input_tokens": tokens.cache?.write,
        "gen_ai.usage.reasoning.output_tokens": tokens.reasoning,
        "langfuse.observation.metadata.uncached_input_tokens": tokens.input,
        "langfuse.observation.metadata.text_output_tokens": tokens.output,
        "error.type": failed,
      }, failed);
    };

    // The task span has no prompt and no title: only the agent and the result.
    const task = (e, error) => {
      const t = tasks.get(e.data.sessionID);
      if (!t) return;
      tasks.delete(e.data.sessionID);
      const failed = error ? errorCategory(e.data.error, error) : undefined;
      span(e.data.sessionID, `invoke_agent ${t.agent ?? "opencode"}`, 1, t.start, e.created, {
        "gen_ai.operation.name": "invoke_agent",
        "gen_ai.agent.name": t.agent,
        "langfuse.observation.metadata.task_result": error === "interrupted" ? "interrupted" : error ? "failed" : "completed",
        "error.type": failed,
      }, failed, t);
    };

    const handle = (e) => {
      const d = e.data ?? {};
      switch (e.type) {
        case "session.execution.started":
          tasks.set(d.sessionID, { traceId: id(16), spanId: id(8), start: e.created });
          break;
        case "session.execution.succeeded":
          task(e);
          break;
        case "session.execution.failed":
          task(e, "task_error");
          break;
        case "session.execution.interrupted":
          task(e, "interrupted");
          break;
        case "session.skill.activated":
          if (safeName(d.name)) span(d.sessionID, "activate_skill", 1, e.created, e.created, {
            "langfuse.observation.type": "EVENT",
            "langfuse.observation.metadata.skill_name": safeName(d.name),
          });
          break;
        case "session.tool.input.started":
          tools.set(d.id, { session: d.sessionID, name: d.name, start: e.created });
          break;
        case "session.tool.called":
          if (tools.has(d.id)) tools.get(d.id).input = d.input;
          break;
        case "session.tool.success":
          tool(e);
          break;
        case "session.tool.failed":
          tool(e, "tool_error");
          break;
        case "session.step.started":
          steps.set(d.assistantMessageID, { start: e.created, model: d.model?.id, provider: d.model?.providerID });
          if (tasks.has(d.sessionID)) tasks.get(d.sessionID).agent ??= d.agent;
          break;
        case "session.step.ended":
          step(e);
          break;
        case "session.step.failed":
          step(e, "step_error");
          break;
      }
    };

    const timer = setInterval(() => void flush(), FLUSH_MS);
    timer.unref?.();
    const abort = new AbortController();
    (async () => {
      for await (const e of ctx.event.subscribe({ signal: abort.signal })) {
        try {
          handle(e);
        } catch {
          eventErrors++;
        }
        // The stream does not end by itself. Without this, the runtime does not stop.
        if (e.type === "location.shutdown") break;
      }
    })()
      .catch(() => { eventErrors++; console.warn("onbehalf telemetry: event stream stopped"); })
      .finally(() => {
        clearInterval(timer);
        return flush();
      });
    return async () => {
      abort.abort();
      clearInterval(timer);
      await sending;
      // Bound shutdown even if the Collector is unavailable.
      for (let i = 0; i < MAX_ATTEMPTS && spans.length > 0; i++) await flush(true);
      if (spans.length > 0) {
        droppedSpans += spans.length;
        spans = [];
        console.warn("onbehalf telemetry: shutdown dropped spans", { droppedSpans });
      }
    };
  },
};
