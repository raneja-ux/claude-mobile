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
  # --edge-ip-version 4 forces IPv4 — required on WSL2 (no IPv6 routing)
  "$CF_BIN" tunnel --url "http://localhost:${PORT}" --edge-ip-version 4 2>&1 | \
    while IFS= read -r line; do
      if echo "$line" | grep -qE 'trycloudflare\.com|ERR|error|warn'; then
        echo "$line"
      fi
      URL=$(echo "$line" | grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' || true)
      if [ -n "$URL" ]; then
        curl -s -X POST http://localhost:8080/api/send \
          -H "Content-Type: application/json" \
          -d "{\"recipient\":\"61450466234\",\"message\":\"$URL\"}" &
      fi
    done &
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
