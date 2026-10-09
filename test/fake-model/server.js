// Fake OpenAI-compatible model for agent tests. Deterministic:
// - a prompt line "RUN: <command>" -> one shell tool call with that command
// - a tool result as last message   -> "onbehalf-agent-done" (or $FAKE_MODEL_DONE)
// - anything else (also title requests without tools) -> "onbehalf-agent-idle"
// - model "blocked-model" -> HTTP 403, as from a provider network rule
const http = require("http");

const DONE = process.env.FAKE_MODEL_DONE || "onbehalf-agent-done";

function text(content) {
  let t = "";
  if (typeof content === "string") t = content;
  else if (Array.isArray(content)) t = content.map((p) => p.text || "").join("\n");
  // OpenCode can send the prompt as a JSON-encoded string, quotes included.
  if (/^".*"$/s.test(t)) {
    try { t = JSON.parse(t); } catch (e) { /* keep as is */ }
  }
  return t;
}

function decide(body) {
  const msgs = body.messages || [];
  const last = msgs[msgs.length - 1] || {};
  if (last.role === "tool") return { text: DONE };
  const hasShell = (body.tools || []).some((t) => t.function && t.function.name === "shell");
  const user = [...msgs].reverse().find((m) => m.role === "user");
  const run = user && /^RUN: (.+)$/m.exec(text(user.content));
  if (run && hasShell) return { tool: { name: "shell", args: { command: run[1] } } };
  return { text: "onbehalf-agent-idle" };
}

const usage = { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 };

// An Azure AI Foundry resource that only allows selected networks answers so.
function blocked(res) {
  res.writeHead(403, { "content-type": "application/json" });
  res.end(JSON.stringify({ error: { code: "403",
    message: "Public access is disabled. Please configure private endpoint." } }));
}

function reply(body, res) {
  if (body.model === "blocked-model") return blocked(res);
  const d = decide(body);
  const id = "chatcmpl-fake-" + Date.now();
  const base = { id, object: "chat.completion.chunk", created: Math.floor(Date.now() / 1000), model: body.model };
  const call = d.tool && {
    index: 0, id: "call_" + Date.now(), type: "function",
    function: { name: d.tool.name, arguments: JSON.stringify(d.tool.args) },
  };

  if (!body.stream) {
    const message = call
      ? { role: "assistant", content: null, tool_calls: [call] }
      : { role: "assistant", content: d.text };
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ...base, object: "chat.completion",
      choices: [{ index: 0, message, finish_reason: call ? "tool_calls" : "stop" }], usage }));
    return;
  }

  res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
  const send = (o) => res.write("data: " + JSON.stringify(o) + "\n\n");
  const delta = call ? { role: "assistant", tool_calls: [call] } : { role: "assistant", content: d.text };
  send({ ...base, choices: [{ index: 0, delta, finish_reason: null }] });
  send({ ...base, choices: [{ index: 0, delta: {}, finish_reason: call ? "tool_calls" : "stop" }] });
  if (body.stream_options && body.stream_options.include_usage) send({ ...base, choices: [], usage });
  res.end("data: [DONE]\n\n");
}

http.createServer((req, res) => {
  if (req.url === "/health") return res.end("ok");
  if (req.method === "GET" && req.url.endsWith("/models")) {
    res.writeHead(200, { "content-type": "application/json" });
    return res.end(JSON.stringify({ object: "list", data: [{ id: "agent-model", object: "model" }] }));
  }
  let raw = "";
  req.on("data", (c) => (raw += c));
  req.on("end", () => {
    try {
      reply(JSON.parse(raw || "{}"), res);
    } catch (e) {
      res.writeHead(400);
      res.end(String(e));
    }
  });
}).listen(8080, () => console.log("fake model on 8080"));
