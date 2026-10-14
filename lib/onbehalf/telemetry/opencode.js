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
import { readFileSync } from "node:fs";
import { createHash, randomBytes } from "node:crypto";
import { homedir, hostname, userInfo } from "node:os";

const CONFIG = "/etc/onbehalf/telemetry.json";
const FLUSH_MS = 5000;
const MAX_BATCH = 200;

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
    const resource = {
      attributes: attributes({
        "service.name": "opencode",
        "host.name": hostname(),
        "onbehalf.harness": "opencode",
      }),
    };

    let spans = [];
    const tools = new Map();
    const steps = new Map();
    const tasks = new Map();

    const flush = async () => {
      if (spans.length === 0) return;
      const batch = spans;
      spans = [];
      try {
        await fetch(`${url.replace(/\/$/, "")}/v1/traces`, {
          method: "POST",
          headers: { "content-type": "application/json", authorization: auth },
          body: JSON.stringify({ resourceSpans: [{ resource, scopeSpans: [{ scope: { name: "onbehalf" }, spans: batch }] }] }),
          signal: AbortSignal.timeout(5000),
        });
      } catch {
        // The Collector is down: these spans are lost.
      }
    };

    // A span of a task is a child of the task span. The task span is the root.
    const span = (session, name, kind, start, end, attrs, error, root) => {
      const task = tasks.get(session);
      spans.push({
        traceId: root?.traceId ?? task?.traceId ?? sessionTrace(session),
        spanId: root?.spanId ?? id(8),
        parentSpanId: root ? undefined : task?.spanId,
        name,
        kind,
        startTimeUnixNano: nanos(start),
        endTimeUnixNano: nanos(end),
        attributes: attributes({ "session.id": session, "gen_ai.conversation.id": session, ...attrs }),
        status: error ? { code: 2 } : { code: 1 },
      });
      if (spans.length >= MAX_BATCH) void flush();
    };

    const tool = (e, error) => {
      const t = tools.get(e.data.id);
      if (!t) return;
      tools.delete(e.data.id);
      const exit = e.data.metadata?.exit;
      // A shell command that ends with an exit code other than 0 failed.
      const failed = error || (typeof exit === "number" && exit !== 0) ? (error ?? "exit_code") : undefined;
      span(t.session, `execute_tool ${t.name}`, 1, t.start, e.created, {
        "gen_ai.operation.name": "execute_tool",
        "gen_ai.tool.name": t.name,
        "gen_ai.tool.type": "function",
        "gen_ai.tool.call.id": e.data.id,
        "process.command_line": typeof t.input?.command === "string" ? t.input.command : undefined,
        "process.exit.code": typeof exit === "number" ? exit : undefined,
        "error.type": failed,
      }, failed);
    };

    const step = (e, error) => {
      const s = steps.get(e.data.assistantMessageID);
      if (!s) return;
      steps.delete(e.data.assistantMessageID);
      const tokens = e.data.tokens ?? {};
      span(e.data.sessionID, `chat ${s.model}`, 3, s.start, e.created, {
        "gen_ai.operation.name": "chat",
        "gen_ai.provider.name": s.provider,
        "gen_ai.request.model": s.model,
        "gen_ai.response.finish_reasons": e.data.finish ? [e.data.finish] : undefined,
        "gen_ai.usage.input_tokens": tokens.input,
        "gen_ai.usage.output_tokens": tokens.output,
        "error.type": error,
      }, error);
    };

    // The task span has no prompt and no title: only the agent and the result.
    const task = (e, error) => {
      const t = tasks.get(e.data.sessionID);
      if (!t) return;
      tasks.delete(e.data.sessionID);
      span(e.data.sessionID, `invoke_agent ${t.agent ?? "opencode"}`, 1, t.start, e.created, {
        "gen_ai.operation.name": "invoke_agent",
        "gen_ai.agent.name": t.agent,
        "error.type": error,
      }, error, t);
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
          // An event with an unknown shape: skip it.
        }
        // The stream does not end by itself. Without this, the runtime does not stop.
        if (e.type === "location.shutdown") break;
      }
    })()
      .catch(() => {})
      .finally(() => {
        clearInterval(timer);
        return flush();
      });
    return async () => {
      abort.abort();
      clearInterval(timer);
      await flush();
    };
  },
};
