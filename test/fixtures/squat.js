// Fake service that another user starts on someone else's port.
// It logs every request it receives, so a test can see what would leak.
const port = Number(process.env.PORT);
require("http")
  .createServer((req, res) => {
    let body = "";
    req.on("data", (d) => (body += d));
    req.on("end", () => {
      console.log("request", req.method, req.url, JSON.stringify(req.headers), body.slice(0, 300));
      res.writeHead(200, { "content-type": "application/json" });
      res.end("{}");
    });
  })
  .listen(port, "127.0.0.1", () => console.log("listening", port));
