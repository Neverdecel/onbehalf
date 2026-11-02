// onbehalf status plugin for OpenCode 2.x. Step 4 of the session board
// design (docs/design/session-board.md).
//
// It records one short status for each session of this runtime in
// ~/.local/state/onbehalf/sessions.json, with mode 600:
//
//   { "SESSION-ID": { "status": "blocked", "title": "...", "directory": "...",
//                     "line": "...", "question": "...", "updated": 1700000000000 } }
//
// status is "in progress", "blocked", "done" or "stopped". line is the last
// line of the last answer. question is the open permission request.
// A board reads the file through the OpenCode API of the user:
//   GET /api/fs/read/.local/state/onbehalf/sessions.json?path=~
//
// The plugin writes only to the home directory of the user. It sends
// nothing to the network. A status error must never stop the runtime.
import { mkdirSync, renameSync, writeFileSync, readFileSync } from "node:fs";
import { homedir } from "node:os";

const DIR = `${homedir()}/.local/state/onbehalf`;
const FILE = `${DIR}/sessions.json`;
const MAX_SESSIONS = 200;
const MAX_LINE = 200;

// The last line of a text that is not empty, with a maximum length.
const lastLine = (text) => {
  const line = String(text ?? "").split("\n").map((l) => l.trim()).filter(Boolean).pop() ?? "";
  return line.length > MAX_LINE ? line.slice(0, MAX_LINE - 1) + "…" : line;
};

export default {
  id: "onbehalf-status",
  setup: async (ctx) => {
    let sessions = {};
    try {
      sessions = JSON.parse(readFileSync(FILE, "utf8"));
    } catch { /* No file yet. */ }

    const save = () => {
      try {
        const ids = Object.keys(sessions).sort((a, b) => sessions[b].updated - sessions[a].updated);
        for (const id of ids.slice(MAX_SESSIONS)) delete sessions[id];
        mkdirSync(DIR, { recursive: true, mode: 0o700 });
        const tmp = `${FILE}.${process.pid}`;
        writeFileSync(tmp, JSON.stringify(sessions, null, 1) + "\n", { mode: 0o600 });
        renameSync(tmp, FILE);
      } catch { /* The next event tries again. */ }
    };
    const update = (id, fields, created) => {
      if (!id) return;
      const s = (sessions[id] ??= { status: "done", title: "", directory: "", line: "", question: "" });
      Object.assign(s, fields, { updated: created ?? Date.now() });
      save();
    };

    const handle = (e) => {
      const d = e.data ?? {};
      const id = d.sessionID;
      switch (e.type) {
        case "session.created":
          return update(id, { directory: d.location?.directory ?? "" }, e.created);
        case "session.renamed":
          return update(id, { title: d.title ?? "" }, e.created);
        case "session.execution.started":
          return update(id, { status: "in progress", question: "" }, e.created);
        case "permission.asked":
          return update(id, { status: "blocked", question: lastLine(`Permission: ${d.action ?? ""} ${(d.resources ?? []).join(" ")}`) }, e.created);
        case "permission.replied":
          if (sessions[id]?.status === "blocked") return update(id, { status: "in progress", question: "" }, e.created);
          return;
        case "session.text.ended":
          if (lastLine(d.text)) return update(id, { line: lastLine(d.text) }, e.created);
          return;
        case "session.execution.succeeded":
          return update(id, { status: "done", question: "" }, e.created);
        case "session.execution.failed":
        case "session.execution.interrupted":
          return update(id, { status: "stopped", question: "" }, e.created);
        case "session.deleted":
          if (sessions[id]) {
            delete sessions[id];
            save();
          }
      }
    };

    const abort = new AbortController();
    (async () => {
      for await (const e of ctx.event.subscribe({ signal: abort.signal })) {
        try {
          handle(e);
        } catch { /* Ignore one bad event. */ }
        // The stream does not end by itself. Without this, the runtime does not stop.
        if (e.type === "location.shutdown") break;
      }
    })().catch(() => console.warn("onbehalf status: event stream stopped"));
    return async () => abort.abort();
  },
};
