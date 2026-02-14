#!/usr/bin/env bash
set -euo pipefail

# Pipelock + GeoIP entrypoint.
# 1. Run initial GeoIP refresh (merges country CIDRs into Pipelock config)
# 2. Start cron for weekly refresh
# 3. Start Pipelock with merged config

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] entrypoint: $*"; }

# Ensure base config exists
if [ ! -f /config/pipelock-base.yaml ]; then
  log "ERROR: /config/pipelock-base.yaml not found"
  exit 1
fi

# Persist env vars for cron (cron does not inherit container env)
env | grep -E '^(MAXMIND_|GEODB_|BLOCKED_COUNTRIES_FILE|BASE_CONFIG|MERGED_CONFIG)=' \
  > /etc/environment 2>/dev/null || true

# Initial GeoIP refresh (generates /config/pipelock.yaml)
log "Running initial GeoIP refresh..."
/usr/local/bin/refresh-geodb || {
  log "WARN: GeoIP refresh failed — starting with base config"
  cp /config/pipelock-base.yaml /config/pipelock.yaml
}

# Start cron daemon (for weekly GeoIP refresh)
if command -v cron >/dev/null 2>&1; then
  cron
  log "Cron daemon started (weekly GeoIP refresh)"
fi

# Start Pipelock
log "Starting Pipelock..."
exec /pipelock run --config /config/pipelock.yaml --listen 0.0.0.0:8888
