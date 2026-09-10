# Notes for Melissa — integrating your side with Ian's

**As of 2026-09-10.** Everything below is deployed and verified end to end.
Full detail lives in `INTEGRATION-NOTES.md`; this is the call sheet.

---

## 1. What you need to start

| | |
|---|---|
| **MCP endpoint** | `https://mcp-production-00c3d.up.railway.app/mcp` |
| **Tool names** (public, no auth) | `https://mcp-production-00c3d.up.railway.app/healthz` |
| **Agent token** | `fc38cfe13cebeef3a25eb6e79429c84702324948b7b0ed55` |
| **Audience board** (QR target) | `https://audience-site-production.up.railway.app` |
| **Board admin token** | `b97de3d66a8cb60d66c07d0dc9f61ca65f6fa4d36b9d0f15` |
| Temporal UI (for the on-stage link) | `https://temporal-ui-production-8ab0.up.railway.app` |

Both tokens get rotated after the talk — the URLs will have been on a projector.

The four tools right now: `order_taco`, `order_coffee`, `restock_inventory`,
`send_receipt`. **Read them from `/healthz` rather than hardcoding** — they are
derived from Ian's env vars and the narrative is not final.

---

## 2. Calling a tool

This exact call works today. Copy it.

```bash
curl -X POST https://mcp-production-00c3d.up.railway.app/mcp \
  -H "MCP-Protocol-Version: 2026-07-28" \
  -H "Mcp-Method: tools/call" \
  -H "Mcp-Name: order_taco" \
  -H "Authorization: Bearer <agent token>" \
  -H "Accept: application/json, text/event-stream" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
        "name":"order_taco","arguments":{},
        "_meta":{
          "io.modelcontextprotocol/protocolVersion":"2026-07-28",
          "io.modelcontextprotocol/clientCapabilities":{},
          "idempotencyKey":"batch-7-taco-03"
        }}}'
```

Response — read `result.structuredContent`:

```json
{"service":"Order Taco","completed":true,"response":{"taco":true},
 "attempts":143,"workflow_id":"order_taco-batch-7-taco-03"}
```

### Four things that will each cost you an hour

1. **`params._meta` is mandatory**, not informational. Without those two
   `io.modelcontextprotocol/*` keys you get an instant
   `-32602 params._meta must be an object carrying...` and no workflow starts.
   Headers alone are not enough.
2. **The response is JSON *or* SSE.** Any call running silent past ~15s
   upgrades to `text/event-stream` with `: ping` keepalive comments. Sniff
   `content-type`; if it is SSE, parse the `data:` line. A JSON-only parser
   works in rehearsal and breaks the moment the audience holds a service down —
   which is the whole demo.
3. **Send `MCP-Protocol-Version: 2026-07-28`.** Omit it and you silently fall
   back to a legacy transport with no keepalive; the call dies at ~5 minutes
   behind Railway's proxy.
4. **Set your client timeout above 15 minutes.** The server's own wait cap is
   840s (14 min) and Railway's hard ceiling is 15.

Zero-argument tools: `arguments` is always `{}`.

---

## 3. The mental model — build the dashboard on this

> **A tool call never fails because a service is down. It just takes longer.**

- **Do not build error states for "service down."** You will never see one.
  Every call eventually returns `completed: true`.
- **The number that tells the story is the gap:** `ordered − fulfilled` is how
  many orders are stuck in retry right now. It spikes when the audience breaks
  something and drains to zero when they fix it.
- **`attempts` is your "how broken was it" metric** — and see §4, it is
  effectively a stopwatch in seconds.
- **You cannot detect switch state from the call path.** A toggled-off service
  is absorbed as a retryable failure, indistinguishable from a dead one. Get
  switch state from the board (§5), never by inferring it.

---

## 4. `attempts` is a stopwatch in seconds, not 4/sec

The retry interval is configured at 250ms, but measured gaps between attempts
are locked at exactly 1.000s:

```
1.002  1.007  1.000  1.003  0.994  1.016  0.987  1.001  1.003  1.004
```

This is Temporal's timer granularity — activity retries are server-side timers
with one-second resolution, so a sub-second interval is floored at 1s. Same on
Temporal Cloud; nothing is misconfigured.

**So `attempts` ≈ seconds of outage.** Attempt 143 means that service was down
about 143 seconds. Narrate it that way — it is a better line than "4 retries a
second" anyway. Do not hardcode either rate in a label.

---

## 5. Live switch state — what the crowd just broke

**WebSocket (recommended):**

```
wss://audience-site-production.up.railway.app/ws?role=control&token=<admin token>
```

| Message | Meaning |
|---|---|
| `{t:"hello", state, armed, ts}` | on connect. `state` is `{mcp:false, service_1:true, …}` |
| `{t:"state", id, v, ts}` | one switch moved |
| `{t:"armed", v, ts}` | operator opened/closed the floor |
| `{t:"full", state, ts}` | full resync |
| `{t:"stats", conns, taps, dispatch, bus}` | control role only, once per second |

`conns` is phones connected across all replicas, `taps` is per-switch tap
counts, `dispatch` is the last outbound POST per service with status and
latency, `bus` is Redis health. Reconnect with backoff; the server pings every
25s. A working client hook is `audience-site/src/hooks/useSwitchboard.ts`.

**Or poll REST:** `GET /api/admin/state` with `Authorization: Bearer <admin token>`.

**Joining a switch to a tool: the index N.** `service_1` on the board is the
tool built from `service_1_name`. Those names are now Railway *shared
variables* consumed by both apps, so they cannot drift — that risk is closed.

**The board is locked until Ian opens the floor.** Every switch renders but does
nothing beforehand, and `armed:false` tells you so. Nothing the audience does
registers before that.

---

## 6. Where our contracts still differ

Your v2 spec and what exists differ in ways worth deciding on this call.

| Your v2 expects | Built today | Cost |
|---|---|---|
| `chaos_snapshot` every 200ms: full state, `seq`, `health` 0–100 per component, `damage_per_tap`, `scoreboard` | The board pushes `conns`, per-switch **booleans** and tap counts over its own WebSocket | **Right data, wrong shape.** Needs a translation layer, on one side or the other |
| Health **0–100** with damage-per-tap, fixer/breaker roles, auto-heal | Binary on/off, one Redis flag per service | **Real work**, mostly in the board. Cleanest seam: keep the services binary (down = health 0) and hold the HP in the board |
| Tools take arguments, e.g. `order_more_inventory("chicken", 40)` | **Zero-argument by design.** No input-schema mechanism at all | **Real work** in `mcp_app.py` + `activities.py` + config |
| `out_of_stock` as a business outcome the agent re-plans around | Two states only: `200 {"<name>":true}` or a bare `500` | **Moderate.** Needs a third mode in the Go service |
| Six chaos targets incl. `llm_api`, `agent_worker`, `mcp_link` (yours) | Five switches: `mcp` + `service_1..4`, all Ian's | **Moderate.** The board needs three targets it does not own |
| Tool names `order_a_taco`, `take_payment`, … | `order_taco`, `order_coffee`, `restock_inventory`, `send_receipt` | **Cheap** — env vars, plus one more service deploy if it is five tools |

The two with real design content are **arguments** and **0–100 health**. The
rest is configuration or a shim.

---

## 7. Decisions for this call

1. **Where are you hosting?** If it is this same Railway project, you get
   private networking and the MCP's admin listener for free. If it is
   elsewhere, Ian needs to expose port **8081** publicly (see §8).
2. **Tool names and order** — currently 1 taco, 2 coffee, 3 inventory,
   4 receipt. Four tools or five?
3. **Who owns the `chaos_snapshot` translation** — does the board start emitting
   your shape, or does your backend consume the board's?
4. **Health: booleans or 0–100?** If 0–100, the HP lives in the board and the
   services stay binary.
5. **Do tools need arguments?** This is the expensive one. Zero-argument today.
6. **Idempotency:** pass your `tool_call_id` as `_meta.idempotencyKey` on every
   call. It makes the workflow ID predictable, gives you a Temporal UI deep
   link per order, and is what makes re-issuing a call safe rather than
   ordering a second taco.

---

## 8. The MCP server's admin port (8081)

The MCP server has two listeners:

- **8080** — public, has a domain, serves `/mcp` and `/healthz`. This is what
  you call.
- **8081** — the admin listener: `/admin/live` (live retry counts, 500ms poll),
  `/admin/state`, `/admin/control`, `/admin/reset`. **No public domain today**,
  deliberately.

So a browser cannot reach `/admin/live` right now. If your dashboard runs
outside this Railway project, Ian will add a public domain on 8081 and share
the admin bearer.

⚠️ **Worth knowing before that happens:** the MCP server grants the admin role
based on *which listener* received the request. Putting a public domain on 8081
means anyone holding the admin token can reach the admin control plane from the
internet — including turning services off mid-demo. The token becomes the only
thing standing between the internet and the demo. Options: accept it with a
long rotated token, restrict it to read-only routes, or host your dashboard in
the same Railway project and skip the exposure entirely.

Alternative that needs nothing exposed: your dashboard's own ledger (§3) plus
the board's WebSocket (§5) already give you ordered/fulfilled, the gap, and
switch state. `/admin/live` is a nice-to-have, not a dependency.
