#!/usr/bin/env bash
set -euo pipefail

# Pipelock + Squid + GeoIP + threat feeds entrypoint.
# 1. Run initial GeoIP refresh (merges country CIDRs into Pipelock config)
# 2. Run initial threat feed refresh (merges blocklist domains into config)
# 3. Generate Squid ACL files from merged config
# 4. Start cron for scheduled refresh (monthly GeoIP, daily threats)
# 5. Start Squid in background (CONNECT proxy on :3128)
# 6. Start Pipelock in foreground (fetch proxy on :8888)

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] entrypoint: $*"; }

# Ensure base config exists
if [ ! -f /config/pipelock-base.yaml ]; then
  log "ERROR: /config/pipelock-base.yaml not found"
  exit 1
fi

# Persist env vars for cron (cron does not inherit container env)
env | grep -E '^(GEODB_|BLOCKED_COUNTRIES_FILE|BASE_CONFIG|MERGED_CONFIG|THREATS_)=' \
  > /etc/environment 2>/dev/null || true

# Initial GeoIP refresh (generates /config/pipelock.yaml)
log "Running initial GeoIP refresh..."
/usr/local/bin/refresh-geodb || {
  log "WARN: GeoIP refresh failed — starting with base config"
  cp /config/pipelock-base.yaml /config/pipelock.yaml
}

# Initial threat feed refresh (expands blocklist in merged config)
log "Running initial threat feed refresh..."
/usr/local/bin/refresh-threats || {
  log "WARN: Threat feed refresh failed — continuing with base blocklist"
}

# Generate Squid ACL files from merged Pipelock config
log "Generating Squid ACLs..."
/usr/local/bin/generate-squid-acls || {
  log "WARN: Squid ACL generation failed — Squid will start with empty ACLs"
}

# Start cron daemon (monthly GeoIP + daily threat feeds)
if command -v cron >/dev/null 2>&1; then
  cron
  log "Cron daemon started (monthly GeoIP, daily threat feeds)"
fi

# ── Signal handling for clean shutdown ─────────────────────────────
SQUID_PID=""

cleanup() {
  log "Shutting down..."
  if [ -n "${SQUID_PID}" ] && kill -0 "${SQUID_PID}" 2>/dev/null; then
    log "Stopping Squid (PID ${SQUID_PID})..."
    squid -k shutdown 2>/dev/null || kill "${SQUID_PID}" 2>/dev/null
    wait "${SQUID_PID}" 2>/dev/null || true
  fi
  log "Shutdown complete"
  exit 0
}

trap cleanup SIGTERM SIGINT SIGQUIT

# ── Start Squid (background) ──────────────────────────────────────
log "Starting Squid CONNECT proxy on :3128..."
squid -N &
SQUID_PID=$!
log "Squid started (PID ${SQUID_PID})"

# ── Start Pipelock (foreground) ────────────────────────────────────
log "Starting Pipelock fetch proxy on :8888..."
/pipelock run --config /config/pipelock.yaml --listen 0.0.0.0:8888 &
PIPELOCK_PID=$!
log "Pipelock started (PID ${PIPELOCK_PID})"

# Wait for either process to exit
wait -n "${SQUID_PID}" "${PIPELOCK_PID}" 2>/dev/null || true
log "A process exited unexpectedly — shutting down"
cleanup
