// onbehalf telemetry plugin for OpenCode 2.x. OpenCode exports no tool
// data to OpenTelemetry, so this plugin reads the session events and sends
// one span for each tool call and each model step to the local OTel
// Collector of the host. The spans use the OTel GenAI conventions.
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

// One trace for each session, so a backend shows the calls of a session together.
const traceId = (session) => createHash("sha256").update(String(session)).digest("hex").slice(0, 32);
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

    const span = (session, name, kind, start, end, attrs, error) => {
      spans.push({
        traceId: traceId(session),
        spanId: randomBytes(8).toString("hex"),
        name,
        kind,
        startTimeUnixNano: nanos(start),
        endTimeUnixNano: nanos(end),
        attributes: attributes(attrs),
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
        "gen_ai.conversation.id": t.session,
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
        "gen_ai.conversation.id": e.data.sessionID,
        "gen_ai.response.finish_reasons": e.data.finish ? [e.data.finish] : undefined,
        "gen_ai.usage.input_tokens": tokens.input,
        "gen_ai.usage.output_tokens": tokens.output,
        "error.type": error,
      }, error);
    };

    const handle = (e) => {
      const d = e.data ?? {};
      switch (e.type) {
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
