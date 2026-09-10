#!/usr/bin/env bash
#
# Launch the whole demo backend on a laptop, so the audience site can be tested
# against real services, a real MCP server and a real Temporal server.
#
#   ./dev/stack.sh up        start everything, gated on each piece being ready
#   ./dev/stack.sh status    what is running, and what each piece reports
#   ./dev/stack.sh arm       open the floor so the audience switches work
#   ./dev/stack.sh smoke     prove the demo beat end to end
#   ./dev/stack.sh off taco  break a service, the way the audience will
#   ./dev/stack.sh reseed    re-sync the board after driving services directly
#   ./dev/stack.sh logs mcp  follow one log, or all of them
#   ./dev/stack.sh down      stop everything this script started
#
# Written for bash 3.2 (macOS /bin/bash), no associative arrays.

set -euo pipefail

# Node lives behind asdf shims rather than on the default PATH.
export PATH="$HOME/.asdf/shims:$PATH"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/dev/.run"
LOGS="$RUN/logs"
PIDS="$RUN/pids"
BIN="$RUN/bin"

# ---------------------------------------------------------------------------
# Configuration. Override any of these by exporting them first.
# ---------------------------------------------------------------------------
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_URL="${REDIS_URL:-redis://127.0.0.1:$REDIS_PORT}"
TEMPORAL_PORT="${TEMPORAL_PORT:-7233}"
TEMPORAL_UI_PORT="${TEMPORAL_UI_PORT:-8233}"
MCP_PORT="${MCP_PORT:-8080}"
MCP_ADMIN_PORT="${MCP_ADMIN_PORT:-8081}"
SHIM_PORT="${SHIM_PORT:-9200}"
SITE_PORT="${SITE_PORT:-3000}"
AGENT_TOKEN="${AGENT_TOKEN:-dev-agent-token}"
ADMIN_TOKEN="${ADMIN_TOKEN:-dev-admin-token}"
TASK_QUEUE="${TASK_QUEUE:-durable-mcp}"

# key | port | display name | MCP tool description
# The display name is shared by the MCP server (where it becomes the tool name)
# and the audience site (where it becomes the switch label), which is the
# alignment the real deployment needs -- the index N is the only join between a
# switch on the board and a tool on the MCP server.
SERVICES=(
  "taco|9101|Order Taco|Place an order for a taco and wait until the kitchen confirms it."
  "coffee|9102|Order Coffee|Place an order for a coffee and wait until the barista confirms it."
  "inventory|9103|Restock Inventory|Reorder stock from the supplier and wait for confirmation."
  "receipt|9104|Send Receipt|Send the customer their receipt and wait for delivery confirmation."
)

field() { printf '%s' "$1" | cut -d'|' -f"$2"; }
now_ms() { echo $(( $(date +%s) * 1000 )); }

C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_0=$'\033[0m'
say()  { printf '%s\n' "${C_B}==>${C_0} $*"; }
ok()   { printf '%s\n' "  ${C_OK}ok${C_0}   $*"; }
bad()  { printf '%s\n' "  ${C_BAD}fail${C_0} $*"; }
dim()  { printf '%s\n' "${C_DIM}$*${C_0}"; }
die()  { printf '%s\n' "${C_BAD}error:${C_0} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Process bookkeeping
# ---------------------------------------------------------------------------

# spawn <name> -- reads the command from stdin so callers can set env inline.
spawn() {
  local name="$1"; shift
  mkdir -p "$LOGS" "$PIDS"
  "$@" >>"$LOGS/$name.log" 2>&1 &
  echo $! >"$PIDS/$name.pid"
}

pid_of() { [ -f "$PIDS/$1.pid" ] && cat "$PIDS/$1.pid" || echo ""; }

alive() {
  local pid; pid="$(pid_of "$1")"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

port_busy() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

wait_http() {
  local url="$1" tries="${2:-60}" i=0
  while [ "$i" -lt "$tries" ]; do
    curl -fsS -m 2 "$url" >/dev/null 2>&1 && return 0
    i=$((i + 1)); sleep 0.5
  done
  return 1
}

wait_port() {
  local port="$1" tries="${2:-60}" i=0
  while [ "$i" -lt "$tries" ]; do
    port_busy "$port" && return 0
    i=$((i + 1)); sleep 0.5
  done
  return 1
}

# Fails with the tail of the log, which is where the reason always is.
require_ready() {
  local name="$1" what="$2"
  bad "$name did not come up ($what)"
  echo
  dim "--- last 30 lines of $LOGS/$name.log ---"
  tail -30 "$LOGS/$name.log" 2>/dev/null || echo "(no log)"
  exit 1
}

# ---------------------------------------------------------------------------
# up
# ---------------------------------------------------------------------------
cmd_up() {
  for tool in go node npm uv temporal redis-server curl lsof; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
  done

  mkdir -p "$LOGS" "$PIDS" "$BIN"

  # Refuse to start on top of something else rather than producing a stack
  # where one piece is silently talking to a stranger.
  local claimed=""
  for port in "$MCP_PORT" "$MCP_ADMIN_PORT" "$SHIM_PORT" "$SITE_PORT" \
              $(for s in "${SERVICES[@]}"; do field "$s" 2; done); do
    port_busy "$port" && claimed="$claimed $port" || true
  done
  if [ -n "$claimed" ]; then
    die "port(s) already in use:$claimed  (./dev/stack.sh down first?)"
  fi

  # --- redis ---------------------------------------------------------------
  # One instance serves all three apps; their key namespaces do not overlap
  # (toggle:* / switchboard:* / durable_mcp:availability).
  say "redis"
  if redis-cli -p "$REDIS_PORT" ping >/dev/null 2>&1; then
    ok "already running on :$REDIS_PORT (left alone by 'down')"
    rm -f "$RUN/redis.ours"
  else
    spawn redis redis-server --port "$REDIS_PORT" --save '' --appendonly no
    touch "$RUN/redis.ours"
    redis-cli -p "$REDIS_PORT" ping >/dev/null 2>&1 || sleep 1
    redis-cli -p "$REDIS_PORT" ping >/dev/null 2>&1 || require_ready redis "no PONG on :$REDIS_PORT"
    ok "started on :$REDIS_PORT"
  fi

  # --- temporal ------------------------------------------------------------
  say "temporal dev server"
  spawn temporal temporal server start-dev \
    --ip 127.0.0.1 --port "$TEMPORAL_PORT" --ui-port "$TEMPORAL_UI_PORT" --log-level warn
  wait_port "$TEMPORAL_PORT" 80 || require_ready temporal "nothing listening on :$TEMPORAL_PORT"
  ok "frontend :$TEMPORAL_PORT   UI http://127.0.0.1:$TEMPORAL_UI_PORT"

  # --- the four Go services -----------------------------------------------
  say "toggle services (./service, built once, run 4×)"
  ( cd "$ROOT/service" && go build -o "$BIN/toggle-service" . ) \
    || die "go build failed in ./service"
  for entry in "${SERVICES[@]}"; do
    local key port
    key="$(field "$entry" 1)"; port="$(field "$entry" 2)"
    (
      export ENDPOINT="/$key" PORT="$port" REDIS_URL="$REDIS_URL"
      exec "$BIN/toggle-service"
    ) >>"$LOGS/svc-$key.log" 2>&1 &
    echo $! >"$PIDS/svc-$key.pid"
  done
  for entry in "${SERVICES[@]}"; do
    local key port
    key="$(field "$entry" 1)"; port="$(field "$entry" 2)"
    wait_http "http://127.0.0.1:$port/ready" 40 \
      || require_ready "svc-$key" "/ready never returned 200 on :$port"
    ok "/$key on :$port"
  done

  # --- MCP worker and server ----------------------------------------------
  say "mcp (./mcp)"
  ( cd "$ROOT/mcp" && uv sync --extra dev --quiet ) || die "uv sync failed in ./mcp"

  # Both the worker and the server read the same service_N_* variables.
  mcp_env() {
    local i=1
    for entry in "${SERVICES[@]}"; do
      local key port display description
      key="$(field "$entry" 1)"; port="$(field "$entry" 2)"
      display="$(field "$entry" 3)"; description="$(field "$entry" 4)"
      export "service_${i}_url=http://127.0.0.1:$port/$key"
      export "service_${i}_name=$display"
      export "service_${i}_description=$description"
      i=$((i + 1))
    done
    export mcp_agent_tokens="melissa-agent:$AGENT_TOKEN"
    export admin_token="$ADMIN_TOKEN"
    export redis_url="$REDIS_URL"
    export temporal_address="127.0.0.1:$TEMPORAL_PORT"
    export temporal_namespace="default"
    export temporal_task_queue="$TASK_QUEUE"
    export port="$MCP_PORT"
    export admin_port="$MCP_ADMIN_PORT"
  }

  ( mcp_env; cd "$ROOT/mcp" && exec uv run durable-mcp-worker ) \
    >>"$LOGS/mcp-worker.log" 2>&1 &
  echo $! >"$PIDS/mcp-worker.pid"

  ( mcp_env; cd "$ROOT/mcp" && exec uv run durable-mcp ) \
    >>"$LOGS/mcp.log" 2>&1 &
  echo $! >"$PIDS/mcp.pid"

  wait_http "http://127.0.0.1:$MCP_PORT/healthz" 80 \
    || require_ready mcp "/healthz never answered on :$MCP_PORT"
  ok "server  public :$MCP_PORT  internal :$MCP_ADMIN_PORT"
  grep -q "polling task queue" "$LOGS/mcp-worker.log" 2>/dev/null \
    && ok "worker  polling '$TASK_QUEUE'" \
    || ok "worker  started (check dev/.run/logs/mcp-worker.log)"
  dim "     tools: $(curl -fsS "http://127.0.0.1:$MCP_PORT/healthz" | sed 's/.*"tools"://; s/}//')"

  # --- the master-switch shim ---------------------------------------------
  # See dev/mcp-switch-shim.mjs: the audience site's top switch speaks /on and
  # /off, which the MCP server does not serve. This translates. Test harness
  # only -- nothing here is deployed.
  say "mcp master-switch shim"
  (
    export PORT="$SHIM_PORT" MCP_ADMIN_URL="http://127.0.0.1:$MCP_ADMIN_PORT"
    export MCP_ADMIN_TOKEN="$ADMIN_TOKEN"
    exec node "$ROOT/dev/mcp-switch-shim.mjs"
  ) >>"$LOGS/shim.log" 2>&1 &
  echo $! >"$PIDS/shim.pid"
  wait_http "http://127.0.0.1:$SHIM_PORT/health" 30 \
    || require_ready shim "/health never answered on :$SHIM_PORT"
  ok ":$SHIM_PORT -> mcp /admin/control"

  # --- audience site -------------------------------------------------------
  say "audience site (./audience-site)"
  [ -d "$ROOT/audience-site/node_modules" ] \
    || ( cd "$ROOT/audience-site" && npm install ) || die "npm install failed"

  (
    export PORT="$SITE_PORT" HOSTNAME="127.0.0.1"
    export REDIS_URL="$REDIS_URL"
    export admin_token="$ADMIN_TOKEN"
    export mcp_name="AGENT <-> MCP SERVER"
    export mcp_url="http://127.0.0.1:$SHIM_PORT"
    i=1
    for entry in "${SERVICES[@]}"; do
      export "service_${i}_name=$(field "$entry" 3)"
      # Base URL, no path: the site appends /on, /off and /health itself.
      export "service_${i}_url=http://127.0.0.1:$(field "$entry" 2)"
      i=$((i + 1))
    done
    cd "$ROOT/audience-site" && exec npm run dev
  ) >>"$LOGS/site.log" 2>&1 &
  echo $! >"$PIDS/site.pid"

  wait_http "http://127.0.0.1:$SITE_PORT/healthz" 120 \
    || require_ready site "/healthz never answered on :$SITE_PORT"
  ok "http://127.0.0.1:$SITE_PORT"

  echo
  say "up"
  cat <<EOF
  audience board   http://127.0.0.1:$SITE_PORT
  operator panel   http://127.0.0.1:$SITE_PORT/control?token=$ADMIN_TOKEN
  temporal UI      http://127.0.0.1:$TEMPORAL_UI_PORT
  mcp endpoint     http://127.0.0.1:$MCP_PORT/mcp   (Bearer $AGENT_TOKEN)
  stage dashboard  curl -N -H 'authorization: Bearer $ADMIN_TOKEN' \\
                     http://127.0.0.1:$MCP_ADMIN_PORT/admin/live

  ${C_B}The audience gate defaults to LOCKED.${C_0} The five switches on the board are
  inert until you open the floor -- either from the operator panel above, or:

      ./dev/stack.sh arm

  Then: ./dev/stack.sh smoke     prove a dead service does not fail a tool call
            ./dev/stack.sh status
            ./dev/stack.sh logs
EOF
}

# ---------------------------------------------------------------------------
# down
# ---------------------------------------------------------------------------
cmd_down() {
  say "stopping"
  local names="site shim mcp mcp-worker"
  for entry in "${SERVICES[@]}"; do names="$names svc-$(field "$entry" 1)"; done
  names="$names temporal"
  [ -f "$RUN/redis.ours" ] && names="$names redis" || true

  for name in $names; do
    local pid; pid="$(pid_of "$name")"
    [ -z "$pid" ] && continue
    if kill -0 "$pid" 2>/dev/null; then
      # Negative pid targets the process group, so npm/uv wrappers take their
      # children with them instead of orphaning a listener on the port.
      kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      ok "$name (pid $pid)"
    fi
    rm -f "$PIDS/$name.pid"
  done

  sleep 2
  for name in $names; do
    local pid; pid="$(pid_of "$name")"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill -KILL "-$pid" 2>/dev/null || true
  done
  rm -f "$RUN/redis.ours"

  # Anything still holding a port is a leftover from a previous run.
  local stuck=""
  for port in "$MCP_PORT" "$MCP_ADMIN_PORT" "$SHIM_PORT" "$SITE_PORT" \
              $(for s in "${SERVICES[@]}"; do field "$s" 2; done); do
    port_busy "$port" && stuck="$stuck $port" || true
  done
  if [ -n "$stuck" ]; then
    bad "still listening:$stuck   (lsof -nP -iTCP:${stuck# } -sTCP:LISTEN)"
  fi
  say "down"
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
probe() {
  local url="$1"
  curl -fsS -m 2 "$url" 2>/dev/null | head -c 120 || echo "-"
}

cmd_status() {
  printf '%-14s %-7s %-8s %s\n' COMPONENT PORT PROC REPORTS
  printf '%-14s %-7s %-8s %s\n' -------------- ------- -------- -------

  local rstate="down"
  redis-cli -p "$REDIS_PORT" ping >/dev/null 2>&1 && rstate="PONG"
  printf '%-14s %-7s %-8s %s\n' redis "$REDIS_PORT" \
    "$(alive redis && echo ours || echo external)" "$rstate"

  printf '%-14s %-7s %-8s %s\n' temporal "$TEMPORAL_PORT" \
    "$(alive temporal && echo up || echo down)" \
    "$(port_busy "$TEMPORAL_PORT" && echo listening || echo -)"

  for entry in "${SERVICES[@]}"; do
    local key port
    key="$(field "$entry" 1)"; port="$(field "$entry" 2)"
    printf '%-14s %-7s %-8s %s\n' "svc/$key" "$port" \
      "$(alive "svc-$key" && echo up || echo down)" \
      "$(probe "http://127.0.0.1:$port/health")"
  done

  printf '%-14s %-7s %-8s %s\n' mcp "$MCP_PORT" \
    "$(alive mcp && echo up || echo down)" "$(probe "http://127.0.0.1:$MCP_PORT/healthz")"
  printf '%-14s %-7s %-8s %s\n' mcp-worker - \
    "$(alive mcp-worker && echo up || echo down)" -
  printf '%-14s %-7s %-8s %s\n' shim "$SHIM_PORT" \
    "$(alive shim && echo up || echo down)" "$(probe "http://127.0.0.1:$SHIM_PORT/health")"
  printf '%-14s %-7s %-8s %s\n' site "$SITE_PORT" \
    "$(alive site && echo up || echo down)" "$(probe "http://127.0.0.1:$SITE_PORT/healthz")"

  echo
  say "mcp availability switches"
  curl -fsS -m 2 -H "authorization: Bearer $ADMIN_TOKEN" \
    "http://127.0.0.1:$MCP_ADMIN_PORT/admin/state" 2>/dev/null || echo "  (unreachable)"
  echo
  say "board state"
  curl -fsS -m 2 -H "authorization: Bearer $ADMIN_TOKEN" \
    "http://127.0.0.1:$SITE_PORT/api/admin/state" 2>/dev/null || echo "  (unreachable)"
  echo
}

# ---------------------------------------------------------------------------
# arm / disarm -- open and close the floor
# ---------------------------------------------------------------------------
# The hub reads switchboard:armed once at boot and takes later changes off the
# bus, so setting the key alone would not reach a running replica. Publishing
# the event is what the operator panel does.
cmd_arm() {
  local value="${1:-1}" word="UNLOCKED"
  [ "$value" = "0" ] && word="LOCKED" || true
  redis-cli -p "$REDIS_PORT" SET switchboard:armed "$value" >/dev/null
  redis-cli -p "$REDIS_PORT" PUBLISH switchboard:events \
    "{\"t\":\"armed\",\"v\":$([ "$value" = 1 ] && echo true || echo false),\"ts\":$(now_ms)}" >/dev/null
  ok "audience controls $word"
}

# ---------------------------------------------------------------------------
# on / off -- break a service the way the audience will
#
# These POST the service directly, bypassing the board. That is the point (it
# is the "something other than this app toggled it" case), but it means the
# board's switch positions can drift from what the services actually report.
# `reseed` makes the board re-read /health and catch up; driving the switches
# from /control instead keeps the two in step by construction.
# ---------------------------------------------------------------------------
cmd_toggle() {
  local action="$1" target="${2:-}"
  if [ -z "$target" ]; then
    die "usage: ./dev/stack.sh $action <taco|coffee|inventory|receipt|mcp|all>"
  fi

  if [ "$target" = "mcp" ]; then
    curl -fsS -m 3 -XPOST "http://127.0.0.1:$SHIM_PORT/$action" && echo
    return
  fi

  for entry in "${SERVICES[@]}"; do
    local key port
    key="$(field "$entry" 1)"; port="$(field "$entry" 2)"
    if [ "$target" = "all" ] || [ "$target" = "$key" ]; then
      printf '%-12s ' "$key"
      curl -fsS -m 3 -XPOST "http://127.0.0.1:$port/$action" && echo
    fi
  done
}

# Make the board re-read /health on every service, so its switch positions
# match reality again after `on`/`off` drove the services behind its back.
cmd_reseed() {
  say "reseeding the board from /health"
  curl -fsS -m 10 -XPOST -H "authorization: Bearer $ADMIN_TOKEN" \
    "http://127.0.0.1:$SITE_PORT/api/admin/reseed" || die "reseed failed"
  echo
}

# ---------------------------------------------------------------------------
# call -- one MCP tool call, exactly as Melissa's agent will make it
# ---------------------------------------------------------------------------
mcp_call() {
  local tool="$1" key="${2:-$(date +%s)-$RANDOM}"
  curl -sS -m 900 "http://127.0.0.1:$MCP_PORT/mcp" \
    -H "authorization: Bearer $AGENT_TOKEN" \
    -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' \
    -H 'MCP-Protocol-Version: 2026-07-28' \
    -H 'Mcp-Method: tools/call' \
    -H "Mcp-Name: $tool" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{
          \"name\":\"$tool\",\"arguments\":{},
          \"_meta\":{
            \"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",
            \"io.modelcontextprotocol/clientCapabilities\":{},
            \"io.modelcontextprotocol/clientInfo\":{\"name\":\"stack.sh\",\"version\":\"1\"},
            \"idempotencyKey\":\"$key\"}}}"
}

cmd_call() {
  local tool="${1:-order_taco}"
  mcp_call "$tool" | tr -d '\r' | sed -n 's/^data: //p;/^{/p' | tail -1
  echo
}

# ---------------------------------------------------------------------------
# smoke -- the demo beat, asserted
# ---------------------------------------------------------------------------
cmd_smoke() {
  local out="$RUN/smoke.json"
  say "1. tools the server is exposing"
  curl -fsS "http://127.0.0.1:$MCP_PORT/healthz" || die "mcp /healthz unreachable"
  echo

  say "2. a normal call, everything healthy"
  cmd_toggle on taco >/dev/null
  local first; first="$(cmd_call order_taco)"
  echo "$first" | grep -q '"completed":true' \
    || { echo "$first"; die "a healthy call did not complete"; }
  ok "completed on attempt $(echo "$first" | sed -n 's/.*"attempts":\([0-9]*\).*/\1/p')"

  say "3. kill the taco service, then call it anyway"
  cmd_toggle off taco >/dev/null
  ok "/taco is returning 500"

  mcp_call order_taco "smoke-$(date +%s)" >"$out" 2>&1 &
  local call_pid=$!
  sleep 4

  if ! kill -0 "$call_pid" 2>/dev/null; then
    cat "$out"; die "the tool call returned while the service was dead -- it should have stayed open"
  fi
  ok "4s in, the call is still open and Temporal is retrying"

  local live
  live="$(curl -fsS -m 3 -H "authorization: Bearer $ADMIN_TOKEN" \
    "http://127.0.0.1:$MCP_ADMIN_PORT/admin/state" 2>/dev/null || echo '')"
  dim "     switches: $live"

  say "4. restore the service"
  cmd_toggle on taco >/dev/null
  wait "$call_pid" 2>/dev/null || true

  local result attempts
  result="$(tr -d '\r' <"$out" | sed -n 's/^data: //p;/^{/p' | tail -1)"
  echo "$result" | grep -q '"completed":true' \
    || { echo "$result"; die "the call did not complete after the service came back"; }
  attempts="$(echo "$result" | sed -n 's/.*"attempts":\([0-9]*\).*/\1/p')"
  ok "completed after $attempts attempts, with no error surfaced to the caller"

  echo
  say "that is the whole demo"
  dim "  The audience broke a service. The agent's call never failed -- it took"
  dim "  $attempts tries instead of 1. Ordered and fulfilled still match."
}

# ---------------------------------------------------------------------------
# logs / reset
# ---------------------------------------------------------------------------
cmd_logs() {
  mkdir -p "$LOGS"
  if [ $# -gt 0 ]; then
    tail -f "$LOGS/$1.log"
  else
    dim "following all logs -- ctrl-c to stop"
    tail -f "$LOGS"/*.log
  fi
}

cmd_reset() {
  say "wiping demo state from redis"
  for pattern in 'toggle:*' 'switchboard:*'; do
    redis-cli -p "$REDIS_PORT" --scan --pattern "$pattern" | while read -r k; do
      [ -n "$k" ] && redis-cli -p "$REDIS_PORT" DEL "$k" >/dev/null || true
    done
    ok "$pattern"
  done
  redis-cli -p "$REDIS_PORT" DEL durable_mcp:availability >/dev/null
  ok "durable_mcp:availability"
  dim "the Go services reseed their last-known state within 250ms, so restart"
  dim "them (or use 'on all') if you want a known position."
}

# ---------------------------------------------------------------------------
usage() {
  sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  up)      shift; cmd_up "$@" ;;
  down)    shift; cmd_down "$@" ;;
  restart) cmd_down; echo; cmd_up ;;
  status)  shift; cmd_status "$@" ;;
  arm)     cmd_arm 1 ;;
  disarm)  cmd_arm 0 ;;
  on)      shift; cmd_toggle on "$@" ;;
  off)     shift; cmd_toggle off "$@" ;;
  reseed)  cmd_reseed ;;
  call)    shift; cmd_call "$@" ;;
  smoke)   shift; cmd_smoke "$@" ;;
  logs)    shift; cmd_logs "$@" ;;
  reset)   cmd_reset ;;
  ""|-h|--help|help) usage ;;
  *)       die "unknown command '$1'  (try: ./dev/stack.sh help)" ;;
esac
