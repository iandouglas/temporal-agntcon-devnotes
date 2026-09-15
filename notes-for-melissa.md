# Notes for Melissa — integrating your side with Ian's

**As of 2026-09-15.** Everything below is deployed and verified end to end.
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
- **You cannot detect component state from the call path.** A component the room
  has voted down is absorbed as a retryable failure, indistinguishable from a
  dead one. Get state from the board (§5), never by inferring it.

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

## 5. Live component state — what the crowd just broke

> **Changed 2026-09-11.** The board used to be five on/off switches anyone could
> flip. It is now a **breaker-vs-fixer tug of war**. The boolean you may have
> built against still exists — it is just derived now instead of set.

Every viewer is put on a **team** at first load (round-robin, pinned by a
`mep_role` cookie) and gets one button per component: **BREAK** or **FIX**. All
five take part, the agent ↔ MCP connection included.

Each component carries a vote tally rather than a flag:

```jsonc
{ "breaks": 156, "fixes": 44, "on": false }
```

`on` is derived: **up while the fixers hold at least half the vote**, which
reduces to `fixes >= breaks`. So a 0–0 tie starts every component up, and the
first vote either way swings the bar to an end.

**A vote always moves the bar; only a vote that flips `on` calls the service.**
Expect the tally to climb continuously while `state` events arrive only at
crossings — that is the design, not a dropped message.

### WebSocket

```
wss://audience-site-production.up.railway.app/ws?role=control&token=<admin token>
```

| Message | Meaning |
|---|---|
| `{t:"hello", state, tallies, names, role, armed, ts}` | on connect |
| `{t:"tallies", tallies, ts}` | vote counts changed — ~8/sec, whole snapshot, a dropped frame self-corrects |
| `{t:"state", id, v, ts}` | a component crossed the line and was actually called |
| `{t:"names", names, ts}` | a component was renamed live |
| `{t:"armed", v, ts}` | operator opened/closed the floor |
| `{t:"full", state, ts}` | full resync |
| `{t:"stats", conns, taps, dispatch, bus}` | control role only, once per second |

`stats.conns` is phones connected. `stats.taps` is raw clicks including ones the
rate limiter dropped, so it runs **ahead of** `tallies` — use `tallies` for the
bars and `taps` only as a crowd-energy number.

**Or poll REST:** `GET /api/admin/state` with the admin bearer gives `state`,
`names`, `armed`, `conns`, `bus`, `pool`. It does **not** include `tallies` —
use the socket for those.

### Getting health 0–100 out of it

```
health[id] = round(fixes / (fixes + breaks) * 100)     // 0-0 tie → 50
```

That is your `health` field. **But it is a ratio, so a click's effect shrinks as
votes pile up** — at 400–400 one tap moves it 0.1%, and late in a round the
percentage looks frozen while the counts keep climbing. There is therefore no
fixed `damage_per_tap` to publish.

The board shows both numbers for exactly this reason:

```
22% (44 fixes)    UP    (156 breaks) 78%
```

If your dashboard needs a bar that stays lively all round, narrate the counts
rather than the percentage, or ask Ian for a windowed/decaying health instead of
a cumulative ratio. `RESET COUNTERS` un-sticks it instantly.

### Joining a component to a tool

By **index**, not by name. `service_1` on the board is the tool built from
`service_1_name`.

Do not join by name: display names are now **live-editable** from Redis
(`POST /api/admin/name?id=service_2&name=Order%20Churro`, or inline on
`/control`) and every phone relabels without a reload — but the **MCP server
still takes its tool names from the env var**. That is deliberate: a tool name
is a contract you may be mid-call against, so renaming it live would break
in-flight work. The consequence is that the board can read "Order Churro" while
the tool is still `order_coffee`. Label from `/healthz` or from the board's
`names`, and do not assume they agree.

### Things that will move the board without the audience touching it

- **The floor is locked until Ian opens it.** Buttons render and do nothing;
  `armed:false` tells you.
- **RESET COUNTERS** zeroes every tally *and drives anything down back up*.
  Expect a burst of `state` events. It is the pre-show reset.
- **Operator force** (ALL ON / ALL OFF) moves the tally too, so the board never
  disagrees with reality.

## 6. Where our contracts still differ

Your v2 spec and what exists differ in ways worth deciding on this call.

| Your v2 expects | Built today | Cost |
|---|---|---|
| `chaos_snapshot` every 200ms: full state, `seq`, `health` 0–100 per component, `damage_per_tap`, `scoreboard` | The board pushes `tallies` (~8/sec), `state` on crossings and `names` on rename — all whole snapshots, not diffs | **Shape and cadence only.** An adapter either way; the data is there. **Who writes it is decision 3 below** |
| Health **0–100** with damage-per-tap, fixer/breaker roles, auto-heal | **Mostly built.** Teams, per-component contest and continuous health as a vote ratio (§5). Services stayed binary and the contest lives in the board, as you suggested | **Small.** No `damage_per_tap` value exists because health is a ratio (§5). Room mood and auto-heal are not built |
| Tools take arguments, e.g. `order_more_inventory("chicken", 40)` | **Zero-argument by design.** No input-schema mechanism at all | **Real work** in `mcp_app.py` + `activities.py` + config |
| `out_of_stock` as a business outcome the agent re-plans around | Two states only: `200 {"<name>":true}` or a bare `500` | **Moderate.** Needs a third mode in the Go service |
| Six chaos targets incl. `llm_api`, `agent_worker`, `mcp_link` (yours) | Five components: `mcp` + `service_1..4`, all Ian's | **Moderate.** The board needs three targets it does not own |
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
3. **Who owns the `chaos_snapshot` adapter** — does the board start emitting your
   single 200ms frame, or does your backend assemble it from the board's frames
   plus your own state? The board's frames are already whole snapshots, so
   either direction is mechanical. This is the one that blocks you.
4. ~~**Health: booleans or 0–100?**~~ **Settled** — 0–100, derived from the vote
   ratio, HP in the board, services binary. Read §5 for the formula and the
   ratio caveat.
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

So a browser cannot reach `/admin/live` right now.

Related: the board's agent ↔ MCP card now has a working BREAK/FIX pair and its
votes tally correctly, but the outbound call still goes nowhere, because the MCP
server has no `/on` or `/off` route. **Do not build dashboard behaviour around
that component's state until Ian wires it** — the other four are real. If your dashboard runs
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
component state. `/admin/live` is a nice-to-have, not a dependency.
