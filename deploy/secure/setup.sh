#!/usr/bin/env bash
set -euo pipefail

# Secure OpenClaw — first-time setup script.
# Run this after cloning and before `docker compose up`.
#
# What it does:
#   1. Copies config templates (.env, openclaw.json)
#   2. Generates a gateway auth token
#   3. Creates workspace directories
#   4. Sets restrictive file permissions
#   5. Initializes ClawSec soul-guardian baselines
#   6. Optionally configures Tailscale Serve

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

echo "=== Secure OpenClaw Setup ==="

# ── 1. Environment file ────────────────────────────────────────
if [ ! -f .env ]; then
  cp .env.example .env
  # Generate gateway token
  TOKEN=$(openssl rand -hex 32)
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "s/^OPENCLAW_GATEWAY_TOKEN=$/OPENCLAW_GATEWAY_TOKEN=${TOKEN}/" .env
  else
    sed -i "s/^OPENCLAW_GATEWAY_TOKEN=$/OPENCLAW_GATEWAY_TOKEN=${TOKEN}/" .env
  fi
  echo "[OK] Created .env with generated gateway token"
else
  echo "[SKIP] .env already exists"
fi

# ── 2. Gateway config ──────────────────────────────────────────
mkdir -p .openclaw
if [ ! -f .openclaw/openclaw.json ]; then
  cp openclaw.example.json .openclaw/openclaw.json
  echo "[OK] Created .openclaw/openclaw.json from template"
  echo "     Edit this file to set your channel IDs and preferences"
else
  echo "[SKIP] .openclaw/openclaw.json already exists"
fi

# ── 3. Workspace directories ───────────────────────────────────
mkdir -p .openclaw/workspace
mkdir -p .openclaw/workspace-work
mkdir -p .openclaw/workspace-public
mkdir -p .openclaw/shared-knowledge
echo "[OK] Created workspace directories"

# ── 4. File permissions (security hardening) ───────────────────
chmod 700 .openclaw
chmod 600 .openclaw/openclaw.json
chmod 600 .env
# Auth profiles (if they exist)
find .openclaw -name "auth-profiles.json" -exec chmod 600 {} \; 2>/dev/null || true
echo "[OK] Restrictive file permissions set (700/600)"

# ── 5. ClawSec soul-guardian baseline ──────────────────────────
for workspace in .openclaw/workspace .openclaw/workspace-work; do
  if [ -d "${workspace}" ]; then
    # Create template identity files if missing
    for file in SOUL.md IDENTITY.md TOOLS.md; do
      if [ ! -f "${workspace}/${file}" ]; then
        touch "${workspace}/${file}"
      fi
    done
    # Generate integrity baseline
    (cd "${workspace}" && sha256sum SOUL.md IDENTITY.md TOOLS.md 2>/dev/null > .clawsec-baseline.sha256 || true)
  fi
done
echo "[OK] ClawSec soul-guardian baselines initialized"

# ── 6. Tailscale Serve (optional) ──────────────────────────────
SETUP_TAILSCALE="${SETUP_TAILSCALE:-0}"
if [ "${SETUP_TAILSCALE}" = "1" ]; then
  if command -v tailscale >/dev/null 2>&1; then
    # Check if tailscale is connected
    if tailscale status --json 2>/dev/null | grep -q '"Online":true'; then
      GATEWAY_PORT=$(grep OPENCLAW_GATEWAY_PORT .env | cut -d= -f2)
      GATEWAY_PORT="${GATEWAY_PORT:-18789}"
      echo "Configuring Tailscale Serve on port ${GATEWAY_PORT}..."
      tailscale serve --bg "http://localhost:${GATEWAY_PORT}" || {
        echo "[WARN] Tailscale Serve setup failed — configure manually"
      }
      echo "[OK] Tailscale Serve configured"
      echo "     Gateway accessible at: https://$(tailscale status --json | grep -o '"DNSName":"[^"]*' | head -1 | cut -d'"' -f4)"
    else
      echo "[WARN] Tailscale not connected — skipping Serve setup"
      echo "       Run: tailscale up"
    fi
  else
    echo "[WARN] Tailscale not installed — skipping Serve setup"
    echo "       Install: https://tailscale.com/download"
  fi
else
  echo "[INFO] Tailscale Serve setup skipped (set SETUP_TAILSCALE=1 to enable)"
fi

# ── Summary ────────────────────────────────────────────────────
cat <<'SUMMARY'

=== Setup Complete ===

Next steps:
  1. Edit .openclaw/openclaw.json — set your channel IDs:
     - PERSONAL_WHATSAPP_NUMBER → your phone number
     - PERSONAL_TELEGRAM_ID    → your Telegram user ID
     - DISCORD_GUILD_ID        → your Discord server ID
     - SLACK_USER_ID           → your Slack user ID

  2. Build the OpenClaw image (if not already built):
     docker build -t openclaw:local .

  3. Build sandbox images:
     scripts/sandbox-setup.sh
     scripts/sandbox-common-setup.sh
     scripts/sandbox-browser-setup.sh

  4. Start the stack:
     cd deploy/secure && docker compose up -d

  5. Verify:
     deploy/secure/verify.sh

  6. (Optional) Add Tailscale identity auth:
     SETUP_TAILSCALE=1 deploy/secure/setup.sh
     This runs 'tailscale serve' on the HOST (not in Docker), proxying
     your tailnet to localhost:18789. The gateway trusts Tailscale
     identity headers (allowTailscale: true in config).

  7. (Optional) Connect remote nodes:
     On remote host: openclaw node run --host <gateway-dns> --port 18789
     On gateway:     openclaw nodes pending && openclaw nodes approve <id>
SUMMARY
