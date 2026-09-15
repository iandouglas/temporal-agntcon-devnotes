# Backend integration notes for the dashboard side

**Audience:** Melissa's Claude Code agent (and Melissa).
**Written from:** the code in `./mcp`, `./service`, `./audience-site` as of 2026-09-06.
**Demo:** AGNTcon/MCPcon, October 2026.

Ian owns the three backend pieces described here. This file tells you how to
drive them and how to observe them in real time. Where something is not yet
wired, it says so under [Open items](#open-items-ian--melissa-must-close) rather
than pretending it works.

> **Two documents describe the other half of this demo.** *Richard's Chaos
> Kitchen — demo build spec* (v1, 3 Sep 2026) plans all three subsystems as one
> solo build in a new repo. *Chaos Kitchen Stage* (v2, 3 Sep 2026) supersedes it
> on ownership: its component table marks `llm_api`, `agent_worker` and
> `mcp_link` as `own:"you"` (Melissa's agent + stage screen) and `mcp_worker`,
> `payment_api`, `email_api` as `own:"svc"` — "colleague's API/MCP/audience
> build", i.e. the three pieces in this repo. **v2 is the operative split.**
> It still differs from what is built here on the tool contract, the chaos
> model and the telemetry shape; open item 0 lists every delta.

---

## 1. Topology

```
 Melissa's agent ──── tools/call (HTTPS, blocking) ────▶ mcp service :8080 /mcp
                                                             │  start_workflow
                                                             ▼
                                                       Temporal Cloud
                                                             │  task queue
                                                             ▼
                                                    worker (no public domain)
                                                             │  POST, retry 4×/sec
                                                             ▼
                                   ┌──────────┬──────────┬──────────┬──────────┐
                                   │ service_1│ service_2│ service_3│ service_4│  ← 4 copies of ./service (Go)
                                   └──────────┴──────────┴──────────┴──────────┘
                                                             ▲
 Audience phones ──── WebSocket ──▶ audience-site ── POST /on | /off ──┘
```

Three moving parts:

- **`./service`** — one Go binary, deployed four times with a different
  `ENDPOINT` each. Its one business endpoint returns `200 {"<name>":true}` when
  on, and a bare `500` with no body when off. `/on` and `/off` flip it. State is
  in Redis and shared across all 3 replicas of each service.
- **`./mcp`** — a remote MCP server. Each configured service becomes one
  **zero-argument MCP tool**. Every `tools/call` starts a Temporal workflow and
  **blocks until the work actually completed**.
- **`./audience-site`** — the chaos machine. A QR-code page where every viewer
  is assigned to the **breakers** or the **fixers** and gets one button per
  component (the MCP connection plus the four APIs). Votes are tallied per
  component and the component is up while the fixers hold at least half; only a
  vote that *flips* that calls `/on` or `/off`. The floor is locked until the
  operator opens it from `/control`. See §6.3.

## 1.1 Live deployment (Railway, project `agentcon-demo`)

Everything below is deployed and verified end to end. This closes what was
[open item 5](#open-items-ian--melissa-must-close).

| What | Where |
|---|---|
| **MCP endpoint** | `https://mcp-production-00c3d.up.railway.app/mcp` |
| MCP tool list (public, unauthenticated) | `https://mcp-production-00c3d.up.railway.app/healthz` |
| **Audience board** (the QR target) | `https://audience-site-production.up.railway.app` |
| Board state (REST, admin bearer) | `…/api/admin/state` |
| Board control socket | `wss://audience-site-production.up.railway.app/ws?role=control&token=<admin_token>` |
| Temporal UI | `https://temporal-ui-production-8ab0.up.railway.app` |
| Rehearsal console (one-button arm/disarm) | `https://test-demo-production-bdde.up.railway.app/?key=<console_token>` |

Tokens — **rotate all of these after the talk**, the URLs will have been on a
projector:

| Token | Value | Used for |
|---|---|---|
| agent (`melissa-agent`) | `fc38cfe13cebeef3a25eb6e79429c84702324948b7b0ed55` | `Authorization: Bearer …` on every `tools/call` |
| `admin_token` | `b97de3d66a8cb60d66c07d0dc9f61ca65f6fa4d36b9d0f15` | board REST + control socket, and the MCP server's admin role |
| console token | `166a06ae62fdd376d851c9b8ba79ec198cea4225dc093164` | the rehearsal console only — **not** interchangeable with `admin_token` |

Temporal is **self-hosted on Railway**, not Temporal Cloud: `auto-setup:1.29.0`
against a Railway Postgres, namespace `default`, task queue `durable-mcp`, no
TLS and no API key (private networking only). §6.4's "ask Ian for the Temporal
Cloud namespace and API key" does not apply — if your dashboard wants to read
Temporal directly it must run inside this Railway project and dial
`temporal.railway.internal:7233`.

Scale, as deployed: the four Go services 2 replicas each, `mcp-worker` 2,
**`audience-site` 1**, everything else 1. All services capped at 2 vCPU / 2 GB
except Temporal at 4 vCPU / 8 GB.

The board runs on a single replica deliberately. Vote deltas and renames do
replicate over Redis — verified with two replicas, and with 20 simultaneous
clients all seeing a peer's vote — but for an audience of ~150 one replica is
ample and it removes a whole class of failure from the stage. The cost is that a
redeploy drops every phone at once rather than a fraction of them, which is fine
because nothing is being redeployed mid-demo.

**Turning the demo on.** The board ships locked and every button is inert until
an operator opens the floor. Either press **START THE DEMO** on the rehearsal
console above, or send `{"t":"arm","v":true}` on the control socket. Nothing the
audience does registers before that.

**Config is single-sourced.** `service_N_name`, `service_N_host`,
`service_N_path`, `service_N_description`, `admin_token`, `mcp_agent_tokens` and
the `temporal_*` values are Railway **shared variables**, referenced by each
service. That closes [open item 3](#open-items-ian--melissa-must-close): the
names can no longer drift between `./mcp` and `./audience-site`, because there
is one value. Note `service_N_url` is still assembled differently per app —
the board gets `${{shared.service_N_host}}`, the MCP server gets
`${{shared.service_N_host}}${{shared.service_N_path}}` — because the two apps
genuinely mean different things by it (§6.3).

---

## 2. The mental model to build the dashboard on

> **A tool call never fails because a service is down. It just takes longer.**

Temporal retries the downstream POST every 250ms, forever, with no cap on
attempts. If the audience kills the taco service, the in-flight `order_taco`
call stays open and its attempt counter climbs. When someone flips it back on,
the very next attempt succeeds and the call returns `completed: true` with
`attempts: 143`.

Design consequences for your dashboard:

- **Ordered and fulfilled always reconcile.** Every call you issue eventually
  returns success. Do not build error states for "service down" — you will
  never see them.
- **The interesting number is the gap.** `ordered − fulfilled` is the count of
  orders currently stuck in retry. That is the number that spikes when the
  audience breaks something and drains to zero when they fix it. That is the
  demo.
- **`attempts` in the response is your "how broken was it" metric.** A taco that
  came back on attempt 1 sailed through; one that came back on attempt 400 sat
  through a ~100 second outage.
- **You cannot detect component state from the MCP call path, by design.** A
  component the room has voted down is absorbed as a retryable failure and is
  indistinguishable from a dead downstream. Get state from the audience-site
  (§6.3), never by inferring it from tool behaviour.

---

## 3. Calling the MCP server

### 3.1 Endpoint and headers

`POST https://<mcp-public-domain>/mcp`

These headers are **not optional**. Getting `MCP-Protocol-Version` wrong is
silent at low latency and fatal exactly when the audience starts breaking
things — see §3.5.

| Header | Value |
|---|---|
| `MCP-Protocol-Version` | `2026-07-28` |
| `Mcp-Method` | the JSON-RPC method, e.g. `tools/call` |
| `Mcp-Name` | the tool name for `tools/call`; `""` for `tools/list` |
| `Authorization` | `Bearer <agent token>` (ask Ian; configured as `melissa-agent:<token>`) |
| `Accept` | `application/json, text/event-stream` |
| `Content-Type` | `application/json` |

There is **no `initialize` handshake** in `2026-07-28`. Client info travels in
`params._meta`, and that envelope is **mandatory, not merely informational** —
a call without it is rejected outright with `-32602` before any workflow
starts. The two required keys are shown in §3.2 and §3.3; verified against the
deployed server. The official MCP client SDK v2 does all of this for you; the
raw shape is given below because you will probably want raw HTTP for a
dashboard backend that fires many calls in parallel.

### 3.2 Discovering the tools

The tool names are derived at runtime from Ian's env vars
(`service_N_name` → lowercased, spaces to underscores). **Do not hardcode
them.** Two ways to read them:

```bash
# Unauthenticated, public, cheapest — names only:
curl https://<mcp-domain>/healthz
# {"ok":true,"tools":["order_taco","order_coffee","restock_inventory","send_receipt"]}
```

```jsonc
// Authenticated, full definitions + descriptions:
{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{
  "_meta":{
    "io.modelcontextprotocol/protocolVersion":"2026-07-28",
    "io.modelcontextprotocol/clientCapabilities":{},
    "io.modelcontextprotocol/clientInfo":{"name":"melissa-dashboard","version":"1"}
  }}}
```

`tools/list` results carry `cacheScope: "private"` and `ttlMs: 30000`. Never
cache them in anything shared — the list is filtered per caller role, and a
shared cache could hand an agent the admin tool list.

The working assumption for the four tools is `order_taco`, `order_coffee`,
`restock_inventory`, `send_receipt`, but confirm against `/healthz` on the day.

### 3.3 Calling a tool

Every tool is **zero-argument**. `arguments` is always `{}`.

```jsonc
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "order_taco",
    "arguments": {},
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities": {},
      "io.modelcontextprotocol/clientInfo": {"name": "melissa-dashboard", "version": "1"},
      "idempotencyKey": "batch-7-taco-03"      // ← see §4. Set this.
    }
  }
}
```

### 3.4 The response

The response may arrive as JSON **or** as an SSE stream (the server upgrades to
`text/event-stream` for any call that runs silent past 15 seconds, which is
what keeps Railway's proxy from severing a long call). Handle both: if
`content-type` starts with `text/event-stream`, parse the `data:` line.

Success:

```jsonc
{"jsonrpc":"2.0","id":1,"result":{
  "structuredContent": {
    "service": "Order Taco",           // the human display name
    "completed": true,                 // always true on success
    "response": {"taco": true},        // raw body from the downstream service
    "attempts": 143,                   // Temporal activity attempts — the money number
    "workflow_id": "order_taco-batch-7-taco-03"
  },
  "content": [ /* the same payload as text */ ]
}}
```

Read `result.structuredContent`. That is the contract.

### 3.5 Why the protocol header matters

The SDK routes on `MCP-Protocol-Version`. Send `2026-07-28` and you get the
modern transport, which emits `: ping` SSE comment lines every 15s for a
handler that has not produced output. Omit the header (or send an older
revision) and you silently fall back to the legacy session-based path, which
has **no keepalive and no resumability** — a blocking call gets severed at
about 5 minutes behind Railway's proxy, which is precisely when the audience is
holding a service down. The server logs a loud warning naming the fix if this
happens, so check Ian's logs if a rehearsal call dies at ~5 minutes.

---

## 4. Correlation: idempotency keys and workflow IDs

This is the single most useful thing for the dashboard.

```
workflow_id = "<tool_name>-<idempotencyKey>"
```

If you supply `params._meta.idempotencyKey`, the workflow ID is **deterministic
and known to you before the call returns**. That gives you:

1. **Immediate "ordered" rendering.** Add the row to the dashboard with its
   workflow ID the moment you issue the call, not when it returns.
2. **A join key to `/admin/live`** (§6.2), which reports live attempt counts per
   `workflow_id`.
3. **A clickable Temporal Cloud UI link** per order — very on-message for a
   Temporal talk.
4. **Partial crash recovery — with a real caveat.** A re-issued call with the
   same key attaches to the *existing* workflow
   (`WorkflowIDConflictPolicy.USE_EXISTING`) instead of ordering a second taco,
   and returns the original result — **but only while that workflow is still
   running.** Once it has completed, `USE_EXISTING` no longer applies and
   `id_reuse_policy` takes over; the server sets none, so the default
   `ALLOW_DUPLICATE` starts a *second* run and places a second order.
   Re-calling with the same key is therefore safe for a call still in flight
   and **not** safe for one that already finished.

   The fix is one line in `mcp/src/durable_mcp/mcp_app.py` — pass
   `id_reuse_policy=WorkflowIDReusePolicy.REJECT_DUPLICATE` alongside the
   conflict policy, and read the finished result from the existing handle on
   `WorkflowAlreadyStartedError`. Until that lands, treat "re-call with the
   same key" as a recovery move only for calls you know are still open.

**Keys must be unique per intended order.** Reusing a key deliberately joins the
earlier order. Use something like `` `${batchId}-${tool}-${i}` ``. Without a key
the server mints a random UUID per call, and you lose all four benefits above.

---

## 5. The "order 10 tacos" recipe

> ⚠️ **Confirm this is still the demo.** Both of Melissa's specs describe a
> **single order per run** — v2 runs one 11-step chain for order `#4471`
> ("2 chicken tacos + Fajita Friday · $14.20") in ~90 seconds, and v1 says
> "single order per demo run; no concurrent multi-order scenarios". The
> batch-of-ten pattern below came from Ian's brief and appears in neither.
> Everything in this section still works; it may simply not be the demo.

The batch behaviour — 10 orders, ~1–2s apart, a button for 10 more — maps
directly onto the model in §2. The counters live entirely on your side; you
need no server access to make them correct.

```ts
type Order = {
  key: string;
  workflowId: string;
  tool: string;
  status: "ordered" | "fulfilled";
  issuedAt: number;
  attempts?: number;
  ms?: number;
};

const MCP_URL = process.env.MCP_URL!;            // https://<mcp-domain>/mcp
const TOKEN   = process.env.MCP_AGENT_TOKEN!;

async function callTool(tool: string, key: string) {
  const res = await fetch(MCP_URL, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${TOKEN}`,
      "Content-Type": "application/json",
      "Accept": "application/json, text/event-stream",
      "MCP-Protocol-Version": "2026-07-28",
      "Mcp-Method": "tools/call",
      "Mcp-Name": tool,
    },
    body: JSON.stringify({
      jsonrpc: "2.0", id: 1, method: "tools/call",
      params: {
        name: tool,
        arguments: {},
        _meta: {
          "io.modelcontextprotocol/protocolVersion": "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities": {},
          "io.modelcontextprotocol/clientInfo": { name: "melissa-dashboard", version: "1" },
          idempotencyKey: key,
        },
      },
    }),
    // No client timeout shorter than ~15 min, or you will cut off a call the
    // server would have completed. See §7 for the real ceiling.
    signal: AbortSignal.timeout(900_000),
  });

  const text = await res.text();
  const payload = res.headers.get("content-type")?.startsWith("text/event-stream")
    ? JSON.parse(text.split("\n").find((l) => l.startsWith("data:"))!.slice(5).trim())
    : JSON.parse(text);

  if (payload.error) throw new Error(payload.error.message);   // see §7 — rare
  return payload.result.structuredContent as {
    service: string; completed: boolean; response: unknown;
    attempts: number; workflow_id: string;
  };
}

/** Fire 10 orders, 1.5s apart, without waiting for each to finish. */
async function orderBatch(tool: string, n = 10, gapMs = 1500) {
  const batchId = `b${Date.now().toString(36)}`;
  for (let i = 0; i < n; i++) {
    const key = `${batchId}-${i}`;
    const order: Order = {
      key,
      workflowId: `${tool}-${key}`,     // known NOW, before the call returns
      tool,
      status: "ordered",
      issuedAt: Date.now(),
    };
    store.add(order);                   // dashboard: "ordered" ticks to i+1

    // Deliberately not awaited: orders overlap, which is the whole point —
    // during an outage you want 10 open calls all retrying at once.
    void callTool(tool, key)
      .then((r) => store.fulfil(key, r.attempts, Date.now() - order.issuedAt))
      .catch((e) => store.fail(key, String(e)));   // should never fire; see §7

    if (i < n - 1) await sleep(gapMs);
  }
}
```

**Dashboard tiles that fall out of this, for free:**

| Tile | Source |
|---|---|
| Tacos ordered | count of orders added |
| Tacos fulfilled | count with `status === "fulfilled"` |
| In flight / waiting | ordered − fulfilled |
| Longest wait right now | `max(now − issuedAt)` over unfulfilled orders |
| Retries absorbed | `sum(attempts − 1)` over fulfilled orders |
| Slowest order | `max(ms)` |

The first two **always converge**. If they are diverging on screen, that is not
a bug in your code — it is the audience holding a service down, which is the
demo working.

---

## 6. Real-time status, in order of preference

### 6.1 Your own ledger — primary, and already correct

Everything in the table above needs no backend access at all. Prefer it. It is
the only source that cannot be knocked out by a network problem on stage, and
it is the source of truth for the ordered/fulfilled claim.

### 6.2 `GET /admin/live` on the MCP server — live retry counts

An SSE stream, one `snapshot` event whenever anything changes (polled every
500ms), carrying both switch state and every running workflow:

```jsonc
event: snapshot
data: {
  "state": {
    "global": true,
    "services": [
      {"tool_name":"order_taco","display_name":"Order Taco","description":"…",
       "url":"http://taco.railway.internal:8080/taco",
       "switch": true, "effective": true}
    ]
  },
  "in_flight": [
    {"workflow_id":"order_taco-b7-03","run_id":"…","started_at":"2026-10-21T…",
     "attempt": 143, "last_error":"order_taco: http://… returned 500"}
  ]
}
```

`in_flight[].attempt` is the number that climbs on stage. Join it to your rows
by `workflow_id` (§4). Capped at 25 tracked workflows.

> ⚠️ **This is currently reachable only from inside Railway's private network.**
> It is served on the MCP server's internal listener (`:8081`), which has no
> Railway domain, and requires `Authorization: Bearer <admin_token>`. A browser
> cannot reach it. See [Open items](#open-items-ian--melissa-must-close) — this
> needs a decision from you and Ian before the dashboard can use it.

Sibling endpoints on the same internal listener: `GET /admin/state` (one-shot
version of the `state` block), `POST /admin/control`
(`{"target":"global"|"<tool>","enabled":false}`), `POST /admin/reset`.

### 6.3 The audience-site — what the crowd just broke

This one **is** public HTTPS and browser-reachable today, and it is the right
source for "which component is currently down".

> **This section changed on 2026-09-11.** The board used to be five on/off
> toggles that anyone could flip. It is now a **breaker-vs-fixer tug of war**.
> If you built against booleans, read on — the boolean is still there, but it is
> now derived rather than set.

#### The model

Every viewer is assigned a **team** on first load — round-robin, so the sides
stay even — and pinned to it by a `mep_role` cookie so a reload keeps them where
they were. Each team gets exactly one button per component: **BREAK** for
breakers, **FIX** for fixers. All five components take part, the agent ↔ MCP
connection included.

Each component carries a **vote tally**, not a flag:

```jsonc
{ "breaks": 156, "fixes": 44, "on": false }
```

`on` is **derived, never stored**: a component is up while the fixers hold at
least half the vote. Fixer share ≥ 50% reduces to `fixes >= breaks`, so:

| Votes | Bar | Component |
|---|---|---|
| 0–0 | 50 / 50 | **up** — a tie counts as the fixers holding half |
| 1 break | 100 / 0 breaks | down |
| 1 break, 1 fix | 50 / 50 | up |
| 2 breaks, 1 fix | 66 / 33 | down |

**A vote always moves the bar. Only a vote that flips `on` calls the service.**
A room full of thumbs on one button produces one POST, not hundreds a second.
This is why you will see the tally climb continuously while `state` events
arrive only at crossings.

#### WebSocket

`wss://<audience-host>/ws?role=control&token=<admin_token>`

Server → client (see `audience-site/src/lib/types.ts`):

| Message | Meaning |
|---|---|
| `{t:"hello", state, tallies, names, role, armed, ts}` | On connect. `state` is the derived booleans, `tallies` the vote counts, `names` the display names, `role` your team |
| `{t:"tallies", tallies, ts}` | Vote counts changed. Throttled to ~8/sec, whole snapshot not a diff, so a dropped frame self-corrects |
| `{t:"state", id, v, ts}` | A component crossed the line and was actually called. **Still emitted — the old boolean contract works unchanged** |
| `{t:"names", names, ts}` | A component was renamed live (§6.3.2) |
| `{t:"armed", v, ts}` | Operator opened/closed the floor |
| `{t:"full", state, ts}` | Full resync after a Redis outage or reseed |
| `{t:"stats", conns, taps, dispatch, bus}` | **Control role only**, once per second |

Client → server: `{t:"vote", id}` is the only thing an audience socket may send.
`arm`, `force`, `reset-counters` and `set-name` are accepted **only** on a
control socket; an audience socket sending them is ignored, not errored.

`stats` carries `conns` (phones connected, summed across replicas), `taps` (raw
click count per component, which includes clicks the rate limiter dropped),
`dispatch` (last outbound POST per service with status and latency) and `bus`
(Redis health).

Send `{t:"ping"}` to keep it warm; the server also pings every 25s. Reconnect
with backoff — `audience-site/src/hooks/useSwitchboard.ts` is a working
reference.

**Or poll REST:** `GET /api/admin/state` with `Authorization: Bearer
<admin_token>` returns `state`, `names`, `armed`, `conns`, `bus`, `pool` and the
service list. It does **not** currently include `tallies` — use the socket for
those.

#### Mapping components to tool names

The board identifies components positionally (`mcp`, `service_1` … `service_4`);
the MCP server identifies tools by sanitized name (`order_taco`). The join is
**the index N**: `service_1` on the board is the tool built from
`service_1_name`. Joining by name is not safe — see §6.3.1.

Note `service_N_url` means different things in the two apps: on the board it is
a **base** URL (`http://taco.railway.internal:8080`), on the MCP server it is
the **full endpoint** (`http://taco.railway.internal:8080/taco`). Both are
assembled from the same shared variables, so a host change reaches both.

#### 6.3.1 Display names are live-editable, and may differ from tool names

Component display names live in Redis and can be changed **without a redeploy or
a page reload**: `POST /api/admin/name?id=service_2&name=Order%20Churro` with the
admin bearer, or inline on `/control`. Every connected phone relabels in place
and a `names` frame goes out.

`service_N_name` is only the **seed** — Redis wins once a name has been set, so
a restart will not put the old one back.

⚠️ **The MCP server still derives its tool names from `service_N_name`.** That is
deliberate: a tool name is a contract an agent may be mid-call against, so
renaming it live would break in-flight work. A display name is cosmetic. So the
board can read "Order Churro" while the tool is still `order_coffee`. Harmless
for the join (that is by index), but **label your dashboard from `/healthz` or
from the board's `names`, and do not assume the two agree.**

#### Operator controls that affect what you see

- **The floor is locked until an operator opens it.** Every button renders but
  does nothing, and `armed:false` says so. Nothing the audience does registers
  before that.
- **RESET COUNTERS** returns every tally to 0–0 *and drives anything that was
  down back up*, because the tally is the board's source of truth and must not
  disagree with reality. Expect a burst of `state` events and a `tallies` frame.
  It is the pre-show reset, and it also un-sticks a bar that has gone rigid.
- **Operator force** (ALL ON / ALL OFF, or a single component) moves the tally
  too, for the same reason.

#### Operational notes

Vote counts are persisted to Redis and recovered on boot, so a restart
mid-demo does not reset the game. The board runs as a **single replica** for the
demo; vote deltas and renames do replicate over Redis if it is scaled up, but
one replica removes a class of risk that is not worth carrying on stage.

### 6.3.2 The `chaos_snapshot` contract v2 defines

v2's stage prototype states that its own state object "is deliberately the same
shape the FastAPI backend will push over SSE, so this file doubles as the API
spec": **one snapshot every 200 ms, full state not a diff, a dropped frame
self-corrects.**

```jsonc
{
  "type": "chaos_snapshot",
  "seq": 42,
  "connected": 214,                  // phones connected
  "damage_per_tap": 3,
  "health": {                        // 0-100 per component, NOT booleans
    "llm_api": 100, "agent_worker": 100, "mcp_link": 100,
    "mcp_worker": 100, "payment_api": 100, "email_api": 100
  },
  "run": {
    "workflow_id": "taco-order-4471",
    "status": "IDLE",                // IDLE | RUNNING | REPLAYING | COMPLETED
    "step": 0, "of": 11
  },
  "scoreboard": {
    "history_served": 0, "tokens_not_respent": 0,
    "crashes_survived": 0, "duplicates_prevented": 0,
    "activity_attempts": 0, "activities_completed": 0
  }
}
```

Melissa's backend emits this, but three of its fields are owned by this repo:
`connected` and `damage_per_tap` come from the audience site, `health` for
`mcp_worker` / `payment_api` / `email_api` comes from the audience site, and
`activity_attempts` / `activities_completed` / `duplicates_prevented` come from
the MCP server's Temporal workflows.

**The gap is much smaller than it was.** The board now has exactly the concepts
v2 asked for — fixer and breaker teams, a per-component contest, and a
continuous value rather than a flag:

| v2 field | Where it comes from now |
|---|---|
| `connected` | `stats.conns` on the control socket |
| `health` (0–100) | `tallies[id]` → `round(fixes / (fixes + breaks) * 100)`. A 0–0 tie is 50 |
| `damage_per_tap` | Implicit. One click is one vote, so the *effect* of a tap shrinks as the total grows — see the caveat below |
| `run`, `scoreboard` | Not the board's. Temporal and your own ledger |

What is still unreconciled is the **shape and the cadence**: v2 wants one
`chaos_snapshot` every 200ms carrying everything, and the board emits several
narrower frames (`tallies` at ~8/sec, `state` on crossings, `names` on rename).
Somebody has to write that adapter. **Who owns it is the live question** — the
board could emit v2's shape, or your backend could assemble it from the board's
frames plus your own state. The board's frames are already whole snapshots, not
diffs, so either direction is mechanical.

⚠️ **The `damage_per_tap` caveat.** Because health is a *ratio*, a click's
effect shrinks as votes accumulate: at 400–400 one tap moves the bar 0.1%. There
is no fixed damage number to publish, and late in a heavily-voted round the
percentage will look frozen while the raw counts keep climbing. This is why the
board shows both — `22% (44 fixes) … (156 breaks) 78%`. If your dashboard needs
a bar that stays responsive all round, either narrate the counts rather than the
percentage, or ask Ian for a decaying/windowed health instead of a cumulative
ratio. `RESET COUNTERS` un-sticks it instantly.

### 6.4 Temporal Cloud directly

If your dashboard has a backend, connecting a Temporal client to the same
namespace and listing
`WorkflowType = 'ServiceCallWorkflow' AND ExecutionStatus = 'Running'` gives you
everything `/admin/live` gives you, without needing Ian to expose anything. Ask
Ian for namespace + API key. Also: every order links to the Temporal UI by
workflow ID, which is a strong visual for this particular audience.

---

## 7. What can and cannot go wrong

**Cannot happen** (do not build UI for these):

- A tool call failing because the audience turned a service off.
- A tool call failing because the audience turned the MCP master switch off —
  that is absorbed identically, and the agent genuinely cannot tell the two apart.
- A tool disappearing from `tools/list` while switched off. Tools are never
  removed; a vanishing tool would read as a bug rather than as a failure.

**Can happen:**

| Failure | Symptom | Cause |
|---|---|---|
| `401` | flat HTTP 401 with `WWW-Authenticate` | missing/unknown agent token |
| `-32020 HeaderMismatchError` | JSON-RPC error | `Mcp-Method`/`Mcp-Name` missing or mismatched |
| `-32602` naming `params._meta` | JSON-RPC error, instant | `params._meta` missing the `io.modelcontextprotocol/protocolVersion` + `clientCapabilities` keys (§3.3). Headers alone are not enough |
| `Unknown tool: X` | `ToolError` | wrong tool name, or you tried an `admin_*` tool from a public token |
| Fails in ~1s naming a URL | `ToolError` | non-retryable `4xx` from downstream — a typo'd `service_N_url`. **This is a config bug, not an outage** |
| `"… is still in progress (workflow X)"` | `ToolError` after 14 minutes | the wait cap. **The workflow is still running** and will complete; re-call with the same idempotency key to pick up its result |
| Connection dies at ~5 min | dropped socket | you did not send `MCP-Protocol-Version: 2026-07-28` |

That fourth row is worth internalising: a fast, specific failure means a
**misconfiguration**, while a slow one means a **real outage**. The split exists
so a typo does not spend fourteen minutes looking identical to the demo.

## 8. Timings you may not exceed or contradict

| Constant | Value | Why you care |
|---|---|---|
| Retry interval | 250ms configured, but **~1/sec actual** — see the note below | the rate the counter climbs. `attempts` ≈ seconds of outage |
| Activity `start_to_close` | 3s | a hung service still produces retries |
| HTTP timeout inside the activity | 2.5s | downstream gives up before Temporal does |
| Tool call wait cap | 840s (14 min) | set your client timeout **above** this, ~15 min |
| Railway idle-request timeout | 5 min | survived only via the SSE `: ping` keepalive |
| Railway hard request cap | 15 min | the absolute ceiling on one blocking call |
| `/admin/live` poll | 500ms | your SSE update rate |
| `tools/list` TTL | 30s, `private` scope | do not cache in a shared cache |
| audience-site per-socket rate cap | 5/sec, burst 10 | caps how fast one phone can vote. Dropped clicks are still counted in `stats.taps`, so that number runs ahead of `tallies` |

> **Measured, not assumed.** The attempt counter climbs at **1.00/sec**, not
> ~4/sec. The gaps between consecutive activity attempts, read off the worker's
> own logs, are:
>
> ```
> 1.002  1.007  1.000  1.003  0.994  1.016  0.987  1.001  1.003  1.004
> ```
>
> That is a hard one-second floor, not jitter or queueing latency.
>
> **Nothing in this repo is misconfigured.** `workflows.py` sets
> `initial_interval=250ms`, `backoff_coefficient=1.0`,
> `maximum_interval=250ms`, `maximum_attempts=0`. `./service` returns a bare 500
> immediately on its off branch, and the activity reuses a persistent
> `httpx.AsyncClient`. Task-queue partitions were pinned to 1 to rule out
> partition forwarding; the rate did not budge.
>
> The cause is **Temporal's timer granularity**: activity retries are scheduled
> as server-side timers, whose resolution is one second, so any
> `initial_interval` below 1s is effectively floored at 1s. This is a property
> of Temporal, not of this deployment — expect the same on Temporal Cloud.
>
> **Consequences for the dashboard.** Take `~4 attempts/sec` out of your mental
> model. `attempts` climbs at 1/sec, so it doubles as an outage stopwatch in
> seconds: attempt 143 means the service was down about 143 seconds. That is
> arguably a *better* number to narrate than the original. Do not hard-code
> either rate in a label.
>
> If a genuinely 4/sec counter is wanted, the only way to get one is to move the
> retry loop inside the activity — poll the downstream every 250ms and surface
> the internal count via activity heartbeat details — which changes what
> `attempts` means in the tool response. That is a design decision, not a
> config fix, and it is not currently built.

## 9. Local development without Railway

**One command starts everything:**

```bash
./dev/stack.sh up      # redis, temporal, 4 services, mcp + worker, audience site
./dev/stack.sh arm     # open the floor -- the board is inert until you do
./dev/stack.sh smoke   # assert the demo beat end to end
```

Then the MCP endpoint is `http://127.0.0.1:8080/mcp` with
`Authorization: Bearer dev-agent-token`, the board is on `:3000`, the stage
dashboard is `http://127.0.0.1:8081/admin/live` with
`Authorization: Bearer dev-admin-token`, and the Temporal UI is on `:8233`.
Verified working: a call against a killed service stayed open and completed
after 6 retries with no error surfaced.

`./dev/stack.sh off taco` breaks a service the way the audience will;
`./dev/stack.sh call order_taco` fires one tool call with the exact headers from
§3.1. See `dev/README.md` for the rest.

This is also the fallback if conference wifi fails.

<details><summary>Starting the MCP server by hand instead</summary>

From `./mcp`:

```bash
uv sync --extra dev
uv run durable-mcp-dev-service     # :9100, fake /taco /coffee /inventory /receipt
temporal server start-dev          # separate terminal
export allow_insecure=1            # relaxes auth — local only
export service_1_url=http://127.0.0.1:9100/taco
export service_1_name='Order Taco'
export service_1_description='Order a taco'
uv run durable-mcp-worker          # separate terminal
uv run durable-mcp                 # separate terminal
```

Break a service the way the audience will, and watch the retries:

```bash
curl -XPOST localhost:9100/_chaos/taco -d '{"paused":true}'
curl -N localhost:8081/admin/live
curl -XPOST localhost:9100/_chaos/taco -d '{"paused":false}'
```

With `allow_insecure=1` and no tokens configured, calls to the internal
listener get the admin role, so `/admin/*` works without a token locally.

`./audience-site` runs with `npm run dev`; `./service` with
`REDIS_URL=redis://localhost:6379 ENDPOINT=/taco PORT=8080 go run .`

</details>

---

## Open items (Ian + Melissa must close)

These are real gaps in the current code, not things you can work around from
the dashboard side alone. Raise them with Ian.

0. **v2's contract and what is built here differ in six specific ways.**
   Ownership is settled (v2 assigns the MCP server, the downstream APIs and the
   audience site to this repo); the contract is not. In rough order of cost:

   | # | v2 expects | Built here | Cost |
   |---|---|---|---|
   | a | `order_a_taco`, `order_more_inventory`, `take_payment`, `email_receipt` (+ `get_specials` in the run plan — 4 or 5 tools?) | `order_taco`, `order_coffee`, `restock_inventory`, `send_receipt` | **Cheap.** Tool names are derived from `service_N_name`, so this is env vars plus one more `./service` deploy if it is five |
   | b | `order_more_inventory("chicken", 40)` — tools take arguments | Zero-argument by design (DESIGN.md decision 4): the URL is POSTed with an empty body and there is no input-schema mechanism at all | **Real work.** `mcp_app.py`, `activities.py` and the config all need per-tool input schemas |
   | c | `order_a_taco() → out_of_stock` as a *business outcome* the agent re-plans around | `./service` has exactly two states: `200 {"<name>":true}` or a bare `500`. No third state | **Moderate.** Needs an "out of stock" mode in `./service`; the MCP classification already passes any 2xx body through |
   | d | Health **0–100** per component, with `damage_per_tap`, fixer/breaker roles, room mood, and auto-restart to health 30 after 5s | **Mostly built.** Fixer/breaker teams, per-component contest, continuous health as a vote ratio (§6.3). `./service` stayed binary and the contest lives in the board, as suggested | **Shape only.** What remains is the adapter to v2's single `chaos_snapshot` frame, plus decisions on room mood and auto-restart, which are not built. `damage_per_tap` has no fixed value because health is a ratio — see §6.3.2 |
   | e | Six chaos targets: `llm_api`, `agent_worker`, `mcp_link` (Melissa's) + `mcp_worker`, `payment_api`, `email_api` (ours). Inventory and delivery are *steps, not targets* | Five components: `mcp` + `service_1..4`, all ours | **Moderate.** The board needs three targets it does not own, and drops two it does |
   | f | `take_payment()` interrupted mid-flight resumes and charges **once** ("workflow-id dedup · ran exactly once"), feeding `duplicates_prevented` | One activity that POSTs once. A worker killed mid-activity retries the whole POST, and the missing `id_reuse_policy` (§4) lets a *completed* id start a second run | **One line, plus a decision.** The reuse-policy fix closes the dedup hole if Melissa passes `tool_call_id` as `_meta.idempotencyKey`. True mid-tool resumption would need tool-as-workflow |

   Note b, d and f are the ones with real design content. b and d are the two
   that cannot be absorbed by configuration.

1. **The dashboard has no route to `/admin/live`.** It is on the MCP server's
   internal listener (`:8081`), which deliberately has no Railway domain, so a
   browser cannot reach it. Options: (a) your dashboard backend runs in the same
   Railway project and proxies it over private networking; (b) Ian adds a
   read-only public relay; (c) you read Temporal Cloud directly (§6.4). Until
   one of these is chosen, build against §6.1 + §6.3, which work today.

2. **The audience-site's MCP control does not currently do anything.** Since
   the tug-of-war rework it has a real BREAK/FIX pair, the votes tally and the
   bar moves — but the outbound call still goes nowhere, so the teams can fight
   over the agent ↔ MCP connection and nothing happens to it. One of the five
   cards is inert on stage. The site
   POSTs `{mcp_url}/on` and `{mcp_url}/off` with no auth, but the MCP server has
   no `/on` or `/off` route — it expects
   `POST /admin/control {"target":"global","enabled":false}` with an admin
   bearer token, **on port 8081**. The example config also points `mcp_url` at
   `:8080`. As it stands the top switch on the audience board 404s. Related: the
   site's cold-start probe hits `{mcp_url}/health`, but the MCP server serves
   `/healthz`, so that switch also seeds to a meaningless default. Do not build
   dashboard behaviour around the MCP master switch until this is wired.
   `dev/mcp-switch-shim.mjs` translates between the two dialects so the full
   board is testable locally today, and doubles as the spec for the real fix.

3. ~~**`service_N_name` must be kept identical across `./mcp` and
   `./audience-site`.**~~ **Closed** — it is now a Railway shared variable
   consumed by both apps, so drift is structurally impossible, and the endpoint
   path is single-sourced the same way (§1.1). Historical note: they were
   configured independently, and the two
   `.env.example` files currently disagree (taco/coffee/inventory/receipt versus
   PAYMENTS/SEARCH/AUTH/NOTIFICATIONS). The index N is the only join between a
   board switch and an MCP tool, so if the names drift, your dashboard will
   label the wrong service as broken.

4. **Confirm the four services and their order** — this note assumes
   1 taco, 2 coffee, 3 inventory, 4 receipt, from `mcp/.env.example`. Ian and
   Melissa were still settling the narrative (order → restock → pay → email
   receipt), and the tool names follow whatever is settled.

5. ~~**Ask Ian for:** the MCP public domain, an agent token, the audience-site
   host and its `admin_token`, and the Temporal Cloud namespace and API key.~~
   **Closed — see §1.1.** All URLs and tokens are listed there. Temporal is
   self-hosted on Railway, so there is no Cloud namespace or API key; reading
   Temporal directly means running inside the Railway project.
