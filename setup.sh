#!/usr/bin/env bash
# setup.sh — one-time setup for claude-mobile
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Setting up claude-mobile..."

# 1. Python virtual environment
if [ ! -d .venv ]; then
  echo "--> Creating Python virtual environment..."
  python3 -m venv .venv
fi

echo "--> Installing Python dependencies..."
.venv/bin/pip install --upgrade pip -q
.venv/bin/pip install -r requirements.txt -q

# 2. Copy .env if it doesn't exist
if [ ! -f .env ]; then
  cp .env.example .env
  echo "--> Created .env from .env.example"
  echo "    Edit .env to configure (optional)."
fi

# 3. Download cloudflared
if ! command -v cloudflared &>/dev/null && [ ! -f ./cloudflared ]; then
  echo "--> Downloading cloudflared..."
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  CF_ARCH="amd64" ;;
    aarch64) CF_ARCH="arm64" ;;
    armv7l)  CF_ARCH="arm" ;;
    *)        echo "    WARNING: Unknown arch $ARCH, skipping cloudflared download." && CF_ARCH="" ;;
  esac

  if [ -n "$CF_ARCH" ]; then
    curl -sSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" \
      -o ./cloudflared
    chmod +x ./cloudflared
    echo "--> cloudflared downloaded to ./cloudflared"
  fi
fi

echo ""
echo "✓ Setup complete! Run ./start.sh to launch."
