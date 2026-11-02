// Example interface broker for onbehalf. See README.md.
//
// The reverse proxy does the single sign-on and sets the login header. The
// broker gets the route of that login from `onbehalf route --upn` and sends
// the request to the OpenCode service of that user, with its password.
// The client never gets the password, and it cannot select the user.
//
// No dependencies: Node.js 18 or later.
"use strict";
const fs = require("fs");
const http = require("http");
const { execFile } = require("child_process");

const SOCKET = process.env.BROKER_SOCKET || "/run/onbehalf-broker/broker.sock";
const HEADER = (process.env.BROKER_LOGIN_HEADER || "x-auth-request-preferred-username").toLowerCase();
const ROUTE = (process.env.BROKER_ROUTE || "sudo -n onbehalf route --upn").split(" ");

// The route of one login, or an HTTP error. There is no cache: each request
// gets a new route, so a stopped runtime or a changed port has effect at once.
function route(login) {
  return new Promise((resolve) => {
    if (!login) return resolve({ status: 401, error: "no login from the reverse proxy" });
    execFile(ROUTE[0], [...ROUTE.slice(1), login], { timeout: 10000 }, (err, stdout, stderr) => {
      if (!err) {
        try {
          return resolve({ route: JSON.parse(stdout) });
        } catch {
          return resolve({ status: 502, error: "the route lookup gave no route" });
        }
      }
      // The message of onbehalf has no password. It goes to the log only.
      const msg = String(stderr).trim();
      const down = /does not run|no password|no OpenCode service port/.test(msg);
      resolve({ status: down ? 503 : 403, error: down ? "your runtime does not run" : "no runtime for this login", log: msg });
    });
  });
}

// The headers for the runtime. The client cannot send its own
// authorization, login or cookies of the single sign-on to the runtime.
function upstreamHeaders(req, r) {
  const h = { ...req.headers };
  delete h.authorization;
  delete h.cookie;
  delete h[HEADER];
  h.host = new URL(r.url).host;
  h.authorization = "Basic " + Buffer.from(`${r.username}:${r.password}`).toString("base64");
  return h;
}

function log(login, r, req, status, note) {
  const who = r.route ? r.route.user : "-";
  console.log([new Date().toISOString(), login || "-", who, req.method, req.url.split("?")[0], status, note || ""].join(" ").trim());
}

function refuse(res, login, r, req) {
  log(login, r, req, r.status, r.log);
  res.writeHead(r.status, { "content-type": "text/plain; charset=utf-8" });
  res.end(r.error + "\n");
}

const server = http.createServer(async (req, res) => {
  const login = req.headers[HEADER];
  const r = await route(login);
  if (!r.route) return refuse(res, login, r, req);
  const target = new URL(req.url, r.route.url);
  const up = http.request(target, { method: req.method, headers: upstreamHeaders(req, r.route) }, (upRes) => {
    const h = { ...upRes.headers };
    delete h["www-authenticate"]; // the browser must not ask for the service password
    res.writeHead(upRes.statusCode, h);
    upRes.pipe(res); // also for the event stream (text/event-stream)
    log(login, r, req, upRes.statusCode);
  });
  up.on("error", () => {
    if (!res.headersSent) refuse(res, login, { status: 502, error: "the runtime did not answer" }, req);
    else res.destroy();
  });
  req.pipe(up);
});

// WebSocket connections, for example a terminal in the web interface.
server.on("upgrade", async (req, socket, head) => {
  const login = req.headers[HEADER];
  const r = await route(login);
  if (!r.route) {
    log(login, r, req, r.status, r.log);
    return socket.end(`HTTP/1.1 ${r.status} Refused\r\nconnection: close\r\n\r\n`);
  }
  const up = http.request(new URL(req.url, r.route.url), { method: req.method, headers: upstreamHeaders(req, r.route) });
  up.on("upgrade", (upRes, upSocket, upHead) => {
    const lines = [`HTTP/1.1 ${upRes.statusCode} ${upRes.statusMessage}`];
    for (let i = 0; i < upRes.rawHeaders.length; i += 2) lines.push(`${upRes.rawHeaders[i]}: ${upRes.rawHeaders[i + 1]}`);
    socket.write(lines.join("\r\n") + "\r\n\r\n");
    if (upHead.length) socket.write(upHead);
    if (head.length) upSocket.write(head);
    upSocket.pipe(socket).pipe(upSocket);
    upSocket.on("error", () => socket.destroy());
    socket.on("error", () => upSocket.destroy());
    log(login, r, req, upRes.statusCode);
  });
  up.on("response", (upRes) => {
    socket.end(`HTTP/1.1 ${upRes.statusCode} Refused\r\nconnection: close\r\n\r\n`);
    upRes.resume();
  });
  up.on("error", () => socket.destroy());
  up.end();
});

// Only the reverse proxy can connect: the socket is in a directory that
// only the broker account and the group of the proxy can open.
try {
  fs.unlinkSync(SOCKET);
} catch {}
server.listen(SOCKET, () => {
  fs.chmodSync(SOCKET, 0o660);
  console.log(`broker listens on ${SOCKET}, login header ${HEADER}`);
});
