// A remote MCP server with an OAuth login, for tests. Listens on 127.0.0.1:7777.
// The MCP endpoint /mcp needs a token from /token; /authorize logs anyone in at
// once and sends the browser to the redirect_uri with a code, as a real login
// would after the user signs in.
"use strict";
const http = require("http");
const crypto = require("crypto");
const base = "http://127.0.0.1:7777";
const tokens = new Set();

function json(res, code, body) {
  res.writeHead(code, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

http
  .createServer((req, res) => {
    let body = "";
    req.on("data", (d) => (body += d));
    req.on("end", () => {
      const url = new URL(req.url, base);
      switch (url.pathname) {
        case "/.well-known/oauth-protected-resource":
        case "/.well-known/oauth-protected-resource/mcp":
          return json(res, 200, { resource: `${base}/mcp`, authorization_servers: [base] });
        case "/.well-known/oauth-authorization-server":
          return json(res, 200, {
            issuer: base,
            authorization_endpoint: `${base}/authorize`,
            token_endpoint: `${base}/token`,
            registration_endpoint: `${base}/register`,
            response_types_supported: ["code"],
            grant_types_supported: ["authorization_code", "refresh_token"],
            code_challenge_methods_supported: ["S256"],
            token_endpoint_auth_methods_supported: ["none"],
          });
        case "/register":
          return json(res, 201, { ...JSON.parse(body || "{}"), client_id: "test-client" });
        case "/authorize": {
          const to = new URL(url.searchParams.get("redirect_uri"));
          to.searchParams.set("code", crypto.randomBytes(8).toString("hex"));
          to.searchParams.set("state", url.searchParams.get("state") || "");
          res.writeHead(302, { location: to.toString() });
          return res.end();
        }
        case "/token": {
          const token = `tok-${crypto.randomBytes(8).toString("hex")}`;
          tokens.add(token);
          return json(res, 200, { access_token: token, token_type: "Bearer", expires_in: 3600 });
        }
        case "/mcp": {
          const auth = (req.headers.authorization || "").replace(/^Bearer /, "");
          if (!tokens.has(auth)) {
            res.writeHead(401, {
              "www-authenticate": `Bearer resource_metadata="${base}/.well-known/oauth-protected-resource"`,
            });
            return res.end();
          }
          if (req.method !== "POST") {
            res.writeHead(405);
            return res.end();
          }
          const msg = JSON.parse(body || "{}");
          if (msg.id === undefined) {
            res.writeHead(202);
            return res.end();
          }
          const result =
            msg.method === "initialize"
              ? { protocolVersion: "2025-03-26", capabilities: { tools: {} }, serverInfo: { name: "tracker", version: "1" } }
              : { tools: [] };
          return json(res, 200, { jsonrpc: "2.0", id: msg.id, result });
        }
        default:
          res.writeHead(404);
          return res.end();
      }
    });
  })
  .listen(7777, "127.0.0.1");
