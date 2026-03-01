#!/usr/bin/env bash
# start.sh — start the FastAPI server and Cloudflare tunnel
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load .env for PORT
PORT=8765
if [ -f .env ]; then
  PORT=$(grep -E '^PORT=' .env | cut -d= -f2 | tr -d ' ' || echo "8765")
  PORT="${PORT:-8765}"
fi

# Resolve cloudflared
CF_BIN=""
if command -v cloudflared &>/dev/null; then
  CF_BIN="cloudflared"
elif [ -f ./cloudflared ]; then
  CF_BIN="./cloudflared"
fi

cleanup() {
  echo ""
  echo "Shutting down..."
  kill "$SERVER_PID" 2>/dev/null || true
  [ -n "$BRIDGE_PID" ] && kill "$BRIDGE_PID" 2>/dev/null || true
  [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null || true
  exit 0
}
trap cleanup INT TERM

# Start WhatsApp bridge
BRIDGE_BIN="$HOME/whatsapp-mcp/whatsapp-bridge/whatsapp-bridge"
BRIDGE_PID=""
if [ -f "$BRIDGE_BIN" ]; then
  echo "==> Starting WhatsApp bridge..."
  # Run from its own directory so it finds ./store/whatsapp.db
  (cd "$HOME/whatsapp-mcp/whatsapp-bridge" && "$BRIDGE_BIN") &
  BRIDGE_PID=$!
  sleep 1
  if kill -0 "$BRIDGE_PID" 2>/dev/null; then
    echo "    WhatsApp bridge running (PID $BRIDGE_PID)"
  else
    echo "    WARNING: WhatsApp bridge failed to start — MCP server will be unavailable"
  fi
else
  echo "    WARNING: WhatsApp bridge not found at $BRIDGE_BIN — skipping"
fi

# Start FastAPI server
echo "==> Starting server on port $PORT..."
# Unset CLAUDECODE so the server can spawn its own Claude Code sessions
# (inherited env var would otherwise block nested Claude Code processes)
env -u CLAUDECODE .venv/bin/python server.py &
SERVER_PID=$!

# Give it a moment to bind
sleep 1

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "ERROR: server failed to start." >&2
  exit 1
fi

# Start Cloudflare tunnel
TUNNEL_PID=""
if [ -n "$CF_BIN" ]; then
  echo "==> Starting Cloudflare tunnel..."
  echo ""
  echo "  Your public URL will appear below (look for 'trycloudflare.com'):"
  echo "  Open it on your phone — it's the full chat interface."
  echo "  (Ctrl+C to stop everything)"
  echo ""
  # Named tunnel — permanent URL: https://claude.shoreline-box.com
  # (URL is stable so no need to WhatsApp it each time)
  # For ad-hoc quick tunnels on other projects, use ~/quick-tunnel.sh <port>
  "$CF_BIN" tunnel --config ~/.cloudflared/claude-mobile.yml run claude-mobile 2>&1 | \
    grep -E 'ERR|error|warn|INF' &
  TUNNEL_PID=$!
else
  echo ""
  echo "  cloudflared not found — skipping tunnel."
  echo "  Local access: http://localhost:${PORT}"
  echo "  Install cloudflared and re-run setup.sh for internet access."
  echo "  (Ctrl+C to stop)"
  echo ""
fi

wait "$SERVER_PID"
