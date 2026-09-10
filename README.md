# Running the whole thing on a laptop

`./dev/stack.sh up` starts every backend piece locally so the audience site can
be tested against real services, a real MCP server and a real Temporal server.
No Docker, no Railway, no cloud account.

```
./dev/stack.sh up          start everything (gated on each piece reporting ready)
./dev/stack.sh arm         open the floor -- the board is inert until you do
./dev/stack.sh status      what is running and what each piece reports
./dev/stack.sh smoke       prove the demo beat end to end, with assertions
./dev/stack.sh off taco    break a service the way the audience will
./dev/stack.sh on all      put every service back
./dev/stack.sh reseed      re-sync the board after driving services directly
./dev/stack.sh call order_taco    one MCP tool call, with the exact headers
./dev/stack.sh logs mcp    follow one log (or all of them, with no argument)
./dev/stack.sh reset       wipe demo state from Redis
./dev/stack.sh down        stop everything it started
```

Logs and pidfiles land in `dev/.run/` (gitignored).

## What it starts

| Piece | Port | Notes |
|---|---|---|
| Redis | 6379 | One instance for all three apps; key namespaces do not overlap. An already-running Redis is used as-is and left alone by `down` |
| Temporal dev server | 7233 | UI on http://127.0.0.1:8233 |
| `./service` × 4 | 9101–9104 | `/taco` `/coffee` `/inventory` `/receipt`. Built once, run four times |
| `./mcp` worker | — | Outbound only |
| `./mcp` server | 8080 / 8081 | 8080 public (`/mcp`, `/healthz`), 8081 internal (`/admin/*`) |
| master-switch shim | 9200 | See below |
| `./audience-site` | 3000 | `npm run dev`, so edits hot-reload |

Then:

- **Audience board** — http://127.0.0.1:3000
- **Operator panel** — http://127.0.0.1:3000/control?token=dev-admin-token
- **Stage dashboard** — `curl -N -H 'authorization: Bearer dev-admin-token' http://127.0.0.1:8081/admin/live`

Tokens default to `dev-agent-token` / `dev-admin-token`. Every port and token
is overridable by exporting it before `up` (see the config block at the top of
`stack.sh`).

## Two things that will confuse you

**The audience gate defaults to LOCKED.** All five switches are dead on arrival
until the operator opens the floor — that is deliberate, so a phone that scans
the QR code early cannot drive anything. Run `./dev/stack.sh arm`, or flip
**AUDIENCE CONTROLS** on the operator panel.

**`off taco` and the board can disagree.** `on`/`off` POST the service
directly, bypassing the board, which is exactly the "something else toggled it"
case the audience site warns about. The board keeps showing its own last known
position. `./dev/stack.sh reseed` makes it re-read `/health` and catch up.
Driving switches from `/control` instead keeps the two in step by construction.

## `dev/mcp-switch-shim.mjs`

**A test harness, not part of the demo.** Nothing here is deployed.

The audience site drives all five switches identically: `POST {base}/on`,
`POST {base}/off`, and `GET {base}/health` at cold start. The four Go services
speak that natively. The MCP server does not — it exposes
`POST /admin/control {"target":"global","enabled":bool}` and `GET /admin/state`,
behind an admin bearer token, on its *internal* listener. So the top switch on
the board currently calls a 404.

The shim translates, so the full board is testable locally. It is also the spec
for the real fix: either the audience site learns to speak `/admin/control`, or
the MCP server grows those three routes. See open item 2 in
`../INTEGRATION-NOTES.md`.

## Prerequisites

`go`, `node`, `npm`, `uv`, `temporal`, `redis-server`, `curl`, `lsof`.
`up` checks for all of them and names the missing one. Docker is not needed.

Node is installed via asdf and is not on the default `PATH`; `stack.sh` adds
`~/.asdf/shims` itself, but remember it if you run `npm` by hand.

## What `smoke` asserts

1. `/healthz` lists the four tools.
2. A healthy `order_taco` completes on attempt 1.
3. With `/taco` returning 500, the tool call **stays open** for at least 4s
   rather than failing.
4. Turning `/taco` back on completes the same call, reporting the attempt count.

Step 3 is the one that matters — it is the claim the whole talk rests on. A
representative run: *"completed after 6 attempts, with no error surfaced to the
caller."*
