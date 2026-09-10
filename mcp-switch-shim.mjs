/**
 * Stand-in for the MCP server's missing /on, /off and /health routes.
 *
 * The audience site drives every switch the same way: POST {base}/on, POST
 * {base}/off, and GET {base}/health at cold start. The four Go services speak
 * that dialect natively. The MCP server does not -- it exposes
 * POST /admin/control {"target":"global","enabled":bool} and GET /admin/state,
 * behind an admin bearer token, on its INTERNAL listener (:8081, no public
 * domain). So the top switch on the board currently calls a 404.
 *
 * This translates between the two so the whole board is testable locally. It
 * is a test harness, not part of the demo: nothing here is deployed. It also
 * doubles as the spec for the real fix -- either the audience site learns to
 * speak /admin/control, or the MCP server grows these three routes.
 *
 *   ENDPOINT: on|off -> {"target":"global","enabled":bool} -> /admin/control
 *   ENDPOINT: health -> /admin/state -> {"on": <global switch>}
 */

import { createServer } from "node:http";

const PORT = Number(process.env.PORT ?? 9200);
const ADMIN = (process.env.MCP_ADMIN_URL ?? "http://127.0.0.1:8081").replace(/\/+$/, "");
const TOKEN = process.env.MCP_ADMIN_TOKEN ?? "";

function send(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

async function admin(path, init = {}) {
  const res = await fetch(`${ADMIN}${path}`, {
    ...init,
    headers: { authorization: `Bearer ${TOKEN}`, "content-type": "application/json" },
    signal: AbortSignal.timeout(3000),
  });
  if (!res.ok) throw new Error(`${path} -> HTTP ${res.status}`);
  return res.json();
}

const server = createServer((req, res) => {
  const path = new URL(req.url ?? "/", "http://x").pathname;

  // The switch itself. The audience site POSTs these, one per tap.
  if ((path === "/on" || path === "/off") && req.method === "POST") {
    const enabled = path === "/on";
    admin("/admin/control", {
      method: "POST",
      body: JSON.stringify({ target: "global", enabled }),
    })
      .then((state) => {
        console.log(`[shim] global -> ${enabled ? "on" : "off"}`);
        send(res, 200, { on: state.global });
      })
      .catch((err) => {
        console.error(`[shim] control failed: ${err.message}`);
        send(res, 503, { error: String(err.message) });
      });
    return;
  }

  // Cold-start probe. The audience site's parser accepts {"on":bool}.
  if (path === "/health") {
    admin("/admin/state")
      .then((state) => send(res, 200, { on: state.global }))
      .catch((err) => send(res, 200, { on: true, stale: true, error: String(err.message) }));
    return;
  }

  if (path === "/ready") {
    send(res, 200, { ready: true });
    return;
  }

  send(res, 404, { error: "not found" });
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`[shim] :${PORT} -> ${ADMIN}/admin/control  (translates /on /off /health)`);
});

for (const signal of ["SIGTERM", "SIGINT"]) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
