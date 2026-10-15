// onbehalf telemetry plugin for OpenCode 2.x. OpenCode exports no tool
// data to OpenTelemetry, so this plugin reads the session events and sends
// spans to the local OTel Collector of the host: one trace for each task
// (a prompt), with one span for each model step and each tool call. The
// spans use the OTel GenAI conventions, and session.id for the session.
//
// The plugin sends fixed command labels, never arguments, prompts, answers
// or tool output. It authenticates with the personal
// telemetry key of the user. The Collector sets user.name from that key, so
// a user cannot send spans as a different user.
//
// The plugin does nothing if telemetry is off or the user has no key.
// Telemetry must never stop the runtime: each error is ignored.
import { readFileSync, realpathSync } from "node:fs";
import { createHash, randomBytes } from "node:crypto";
import { homedir, userInfo } from "node:os";

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
const commandLabels = [
  /^(kubectl\s+(?:get|describe|logs|top|explain|diff|apply|create|delete|edit|patch|scale|exec))(?:\s|$)/,
  /^((?:git|rtk\s+git)\s+(?:status|log|diff|show|fetch|push|commit|merge|reset|blame|rev-parse|ls-files|grep|describe|tag|rebase|checkout|switch|restore|clean|rm|mv))(?:\s|$)/,
  /^((?:terraform|tofu)\s+(?:plan|show|validate|apply|destroy|import|output|graph|providers|version))(?:\s|$)/,
  /^(helm\s+(?:list|ls|status|get|history|template|show|search|lint|version|install|upgrade|uninstall|delete|rollback))(?:\s|$)/,
  /^(az\s+(?:group|vm|aks)\s+(?:list|show|create|delete|update|start|stop|restart))(?:\s|$)/,
  /^(rtk\s+(?:recall|ls|cat|head|tail|grep|rg|find|tree|wc|diff|read))(?:\s|$)/,
  /^(docker\s+(?:compose\s+(?:ps|logs|config|up|down|rm|stop|restart)|ps|images|logs|inspect|version|info|run|rm|rmi|stop|kill|push|build|exec))(?:\s|$)/,
  /^(gh\s+(?:pr|issue|run|release|repo|workflow)\s+(?:list|view|status|checks|diff|watch|create|merge|close|reopen|edit|comment|review|ready|delete|upload|fork|rename|archive))(?:\s|$)/,
  /^(aws\s+s3\s+(?:cp|mv|rm|sync|mb|rb|ls))(?:\s|$)/,
  /^(command\s+-v|sed\s+-i|rm|mv|cp|mkdir|rmdir|touch|chmod|chown|ln|tee|dd|truncate|ls|cat|head|tail|grep|rg|find|echo|pwd|cd|wc|jq|which|type|whoami|id|date|printenv|stat|file|du|df|tree|diff|sort|uniq|cut|awk|ps)(?:\s|$)/,
];
// Match only fixed words; never copy an argument or interpret a script as read-only.
const commandSummary = (command) => {
  if (typeof command !== "string" || /[\n\r;&|<>$`()]/.test(command)) return "unknown";
  if (/(^|\s)(-delete|-exec(?:dir)?|-fprint\w*|-fprintf|--output|--out|--write)(?:\s|=|$)/.test(command)) return "unknown";
  for (const pattern of commandLabels) {
    const match = pattern.exec(command.trim());
    if (match) return match[1].replace(/^rtk\s+git\s+/, "git ").replace(/\s+/g, " ");
  }
  return "unknown";
};
const errorCategory = (error, fallback) => {
  if (error?.status === 401) return "authentication";
  if (error?.status === 403) return "permission_denied";
  if (error?.status === 404) return "not_found";
  if (error?.status === 429) return "rate_limit";
  if (error?.status >= 500 && error?.status <= 599) return "service_error";
  const type = typeof error?.type === "string" ? error.type : "";
  if (/interrupt|abort|cancel/i.test(type)) return "interrupted";
  if (/timeout/i.test(type)) return "timeout";
  if (/not[-_.]?found/i.test(type)) return "not_found";
  if (/permission|forbidden|denied/i.test(type)) return "permission_denied";
  if (/authentication|unauthorized/i.test(type)) return "authentication";
  return fallback;
};

export default {
  id: "onbehalf-telemetry",
  setup: async (ctx) => {
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
        "onbehalf.harness": "opencode",
      }),
    };

    let spans = [];
    const tools = new Map();
    const steps = new Map();
    const tasks = new Map();
    // Code Mode uses the outer call ID for every inner call. Input objects
    // distinguish parallel calls, including repeated calls to the same tool.
    const executions = new WeakMap();
    const activeExecutions = new Set();
    const unmatchedCompletions = new Map();
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
        parentSpanId: root ? root.parentSpanId : task?.spanId,
        name,
        kind,
        startTimeUnixNano: nanos(start),
        endTimeUnixNano: nanos(end),
        attributes: attributes({ ...versions, "session.id": session, "gen_ai.conversation.id": session, ...attrs }),
        status: error === null ? { code: 0 } : error ? { code: 2, message: error } : { code: 1 },
      });
      if (spans.length >= MAX_BATCH) void flush();
    };

    const finishTool = (t, end, metadata, error, fallback) => {
      if (t.emitted) return;
      activeExecutions.delete(t);
      if (fallback === "incomplete" && t.command !== undefined) t.command = "unknown";
      const exit = metadata?.exit;
      // A shell command that ends with an exit code other than 0 failed.
      const failed = fallback ? errorCategory(error, fallback)
        : exit === 124 ? "timeout" : exit === 127 ? "command_not_found"
        : typeof exit === "number" && exit !== 0 ? "exit_code"
        : metadata?.error === true || metadata?.isError === true ? "tool_error" : undefined;
      const task = tasks.get(t.session);
      const unobserved = t.observed !== true || fallback === "incomplete" || failed === "interrupted" || t.ambiguous;
      if (task && t.name !== "execute") {
        task.toolCalls++;
        if (failed && failed !== "incomplete" && failed !== "interrupted") task.toolFailures++;
        if (failed === "interrupted") task.toolInterruptions++;
        if (unobserved) task.toolUnobserved++;
      }
      // Unconfirmed dynamic names can be arbitrary model input, not registered tools.
      const name = t.confirmed || ["shell", "skill", "execute"].includes(t.name) ? safeName(t.name) ?? "unknown" : "unknown";
      span(t.session, `execute_tool ${name}`, 1, unobserved ? end : t.start, end, {
        "langfuse.observation.type": unobserved ? "EVENT" : t.name === "execute" ? "SPAN" : "TOOL",
        "gen_ai.operation.name": "execute_tool",
        "gen_ai.tool.name": name,
        "gen_ai.tool.type": "function",
        "gen_ai.tool.call.id": t.callID,
        "process.command_line": t.command === "unknown" ? undefined : t.command,
        "langfuse.observation.metadata.command_summary": t.command,
        "langfuse.observation.metadata.execution_observed": t.observed === true && !unobserved,
        "langfuse.observation.metadata.execution_match": t.ambiguous ? "ambiguous" : fallback === "incomplete" ? "incomplete" : fallback === "interrupted" ? "interrupted" : undefined,
        "process.exit.code": typeof exit === "number" ? exit : undefined,
        "error.type": failed,
      }, failed === "interrupted" || failed === "incomplete" ? null : failed, t);
      t.emitted = true;
    };

    const tool = (e, error) => {
      const t = tools.get(e.data.id);
      if (!t) return;
      tools.delete(e.data.id);
      if (!t.emitted) finishTool(t, e.created, e.data.metadata, e.data.error, error);
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
      span(e.data.sessionID, `chat ${s.model}`, 3, s.start, s.streamed ?? e.created, {
        "langfuse.observation.type": "GENERATION",
        "langfuse.observation.completion_start_time": s.firstToken === undefined ? undefined : new Date(s.firstToken).toISOString(),
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
        "langfuse.observation.metadata.time_to_first_token_ms": s.firstToken === undefined ? undefined : s.firstToken - s.start,
        "langfuse.observation.metadata.time_to_first_text_ms": s.firstText === undefined ? undefined : s.firstText - s.start,
        "langfuse.observation.metadata.retry_count": s.retries ?? 0,
        "langfuse.observation.metadata.stream_boundary_observed": s.streamed !== undefined,
        "error.type": failed,
      }, failed === "interrupted" || failed === "incomplete" ? null : failed);
    };

    // The task span has no prompt and no title: only the agent and the result.
    const task = (e, error) => {
      const t = tasks.get(e.data.sessionID);
      if (!t) return;
      for (const execution of activeExecutions) {
        if (execution.session !== e.data.sessionID) continue;
        const completed = unmatchedCompletions.get(execution.group);
        if (completed?.count > 0) {
          // The result was already recorded without binding it to this start.
          completed.count--;
          execution.emitted = true;
          activeExecutions.delete(execution);
        } else finishTool(execution, e.created, undefined, undefined, error === "interrupted" ? "interrupted" : "incomplete");
      }
      for (const [group, completed] of unmatchedCompletions) if (completed.session === e.data.sessionID) unmatchedCompletions.delete(group);
      for (const [callID, execution] of tools) {
        if (execution.session === e.data.sessionID) {
          if (!execution.emitted) finishTool(execution, e.created, undefined, undefined, error === "interrupted" ? "interrupted" : "incomplete");
          tools.delete(callID);
        }
      }
      for (const [assistantMessageID, modelStep] of steps) {
        if (modelStep.session === e.data.sessionID) step({ ...e, data: { ...e.data, assistantMessageID } }, error === "interrupted" ? "interrupted" : "incomplete");
      }
      tasks.delete(e.data.sessionID);
      const failed = error ? errorCategory(e.data.error, error) : undefined;
      span(e.data.sessionID, `invoke_agent ${t.agent ?? "opencode"}`, 1, t.start, e.created, {
        "langfuse.observation.type": "AGENT",
        "gen_ai.operation.name": "invoke_agent",
        "gen_ai.agent.name": t.agent,
        "langfuse.observation.metadata.task_result": error === "interrupted" ? "interrupted" : error ? "failed" : "completed",
        "langfuse.observation.metadata.time_to_first_text_ms": t.firstText === undefined ? undefined : t.firstText - t.start,
        "langfuse.observation.metadata.tool_call_count": t.toolCalls,
        "langfuse.observation.metadata.tool_failure_count": t.toolFailures,
        "langfuse.observation.metadata.tool_interruption_count": t.toolInterruptions,
        "langfuse.observation.metadata.tool_unobserved_count": t.toolUnobserved,
        "langfuse.observation.metadata.model_step_count": t.modelSteps,
        "langfuse.observation.metadata.retry_count": t.retries,
        "error.type": failed,
      }, error === "interrupted" ? null : failed, t);
    };

    const handle = (e) => {
      const d = e.data ?? {};
      switch (e.type) {
        case "session.execution.started":
          tasks.set(d.sessionID, { traceId: id(16), spanId: id(8), start: e.created, toolCalls: 0, toolFailures: 0, toolInterruptions: 0, toolUnobserved: 0, modelSteps: 0, retries: 0 });
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
          if (!tools.has(d.id)) tools.set(d.id, {
            session: d.sessionID, name: d.name, start: e.created,
            traceId: tasks.get(d.sessionID)?.traceId ?? sessionTrace(d.sessionID),
            spanId: id(8), parentSpanId: tasks.get(d.sessionID)?.spanId, callID: d.id,
          });
          break;
        case "session.tool.called":
          if (tools.has(d.id)) {
            const t = tools.get(d.id);
            t.command = t.name === "shell" ? commandSummary(d.input?.command) : undefined;
          }
          break;
        case "session.tool.success":
          tool(e);
          break;
        case "session.tool.failed":
          tool(e, "tool_error");
          break;
        case "session.step.started":
          steps.set(d.assistantMessageID, { session: d.sessionID, start: d.started ?? e.created, model: d.model?.id, provider: d.model?.providerID });
          if (tasks.has(d.sessionID)) {
            tasks.get(d.sessionID).agent ??= safeName(d.agent);
            tasks.get(d.sessionID).modelSteps++;
          }
          break;
        case "session.step.streamed":
          if (steps.has(d.assistantMessageID)) steps.get(d.assistantMessageID).streamed = e.created;
          break;
        case "session.text.delta":
        case "session.reasoning.delta":
          if (typeof d.delta === "string" && d.delta.length > 0) {
            const s = steps.get(d.assistantMessageID);
            if (s) {
              s.firstToken ??= e.created;
              if (e.type === "session.text.delta") s.firstText ??= e.created;
            }
            if (e.type === "session.text.delta" && tasks.has(d.sessionID)) tasks.get(d.sessionID).firstText ??= e.created;
          }
          break;
        case "session.retry.scheduled":
          if (steps.has(d.assistantMessageID)) steps.get(d.assistantMessageID).retries = (steps.get(d.assistantMessageID).retries ?? 0) + 1;
          if (tasks.has(d.sessionID)) tasks.get(d.sessionID).retries++;
          span(d.sessionID, "model_retry", 1, e.created, e.created, {
            "langfuse.observation.type": "EVENT",
            "langfuse.observation.metadata.retry_attempt": d.attempt,
            "error.type": errorCategory(d.error, "provider_error"),
          });
          break;
        case "session.step.ended":
          step(e);
          break;
        case "session.step.failed":
          step(e, "step_error");
          break;
      }
    };

    // Hooks observe actual execution, not tool-input generation. They also
    // run for inner Code Mode calls which have no session.tool events.
    const registrations = [];
    try {
      registrations.push(await ctx.tool.hook("execute.before", (e) => {
        try {
          if (!e.input || typeof e.input !== "object") return;
          const outer = tools.get(e.id);
          const task = tasks.get(e.sessionID);
          const t = outer?.name === e.tool ? outer : {
            session: e.sessionID, name: e.tool, callID: e.id,
            traceId: outer?.traceId ?? task?.traceId ?? sessionTrace(e.sessionID),
            spanId: id(8), parentSpanId: outer?.spanId ?? task?.spanId,
          };
          t.start = Date.now();
          t.observed = true;
          t.group = JSON.stringify([e.sessionID, e.id, e.tool]);
          t.command = t.name === "shell" ? commandSummary(e.input.command) : undefined;
          executions.set(e.input, t);
          activeExecutions.add(t);
          if (!outer) tools.set(e.id, t);
        } catch { eventErrors++; }
      }));
      registrations.push(await ctx.tool.hook("execute.after", (e) => {
        try {
          const candidates = executions.has(e.input) ? [executions.get(e.input)]
            : [...activeExecutions].filter((t) => t.session === e.sessionID && t.callID === e.id && t.name === e.tool);
          if (candidates.length === 0) { eventErrors++; return; }
          // Never consume an identity record for an unmatched completion:
          // its exact input can still deliver another call's real result.
          if (candidates.length > 1) {
            eventErrors++;
            const group = candidates[0].group;
            const completed = unmatchedCompletions.get(group) ?? { session: e.sessionID, count: 0 };
            completed.count++;
            unmatchedCompletions.set(group, completed);
            const result = { ...candidates[0], name: e.tool, spanId: id(8), confirmed: true, ambiguous: true, emitted: false,
              command: e.tool === "shell" ? commandSummary(e.input?.command) : undefined };
            finishTool(result, Date.now(), e.result?.metadata, e.error, e.status === "error" ? "tool_error" : undefined);
            return;
          }
          const t = candidates[0];
          executions.delete(e.input);
          t.confirmed = true;
          t.name = e.tool;
          t.command = t.name === "shell" ? commandSummary(e.input?.command) : undefined;
          finishTool(t, Date.now(), e.result?.metadata, e.error, e.status === "error" ? "tool_error" : undefined);
        } catch { eventErrors++; }
      }));
    } catch {
      eventErrors++;
      console.warn("onbehalf telemetry: execution hooks unavailable");
    }

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
      for (const registration of registrations) await registration.dispose();
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
