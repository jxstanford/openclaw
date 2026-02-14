#!/usr/bin/env bash
set -euo pipefail

# refresh-geodb.sh — Download db-ip Lite country CSV, extract CIDRs for
# blocked countries, and merge into Pipelock config.
#
# Data source: https://db-ip.com/db/download/ip-to-country-lite
# License: CC BY 4.0 (attribution required)
# No account or API key needed.

GEODB_DIR="${GEODB_DIR:-/var/lib/geogate}"
BLOCKED_COUNTRIES_FILE="${BLOCKED_COUNTRIES_FILE:-/etc/geogate/blocked-countries.conf}"
BASE_CONFIG="${BASE_CONFIG:-/config/pipelock-base.yaml}"
MERGED_CONFIG="${MERGED_CONFIG:-/config/pipelock.yaml}"

# db-ip publishes monthly; URL includes YYYY-MM
DBIP_MONTH=$(date -u +%Y-%m)
DOWNLOAD_URL="https://download.db-ip.com/free/dbip-country-lite-${DBIP_MONTH}.csv.gz"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

# ── Validate prerequisites ─────────────────────────────────────
if [ ! -f "${BLOCKED_COUNTRIES_FILE}" ]; then
  log "WARN: No blocked countries file at ${BLOCKED_COUNTRIES_FILE} — skipping"
  cp "${BASE_CONFIG}" "${MERGED_CONFIG}"
  exit 0
fi

# Read blocked country codes (skip comments and blank lines)
mapfile -t BLOCKED_CODES < <(grep -v '^#' "${BLOCKED_COUNTRIES_FILE}" | grep -v '^\s*$' | tr '[:lower:]' '[:upper:]')

if [ ${#BLOCKED_CODES[@]} -eq 0 ]; then
  log "INFO: No countries to block — copying base config"
  cp "${BASE_CONFIG}" "${MERGED_CONFIG}"
  exit 0
fi

log "Blocked countries: ${BLOCKED_CODES[*]}"

mkdir -p "${GEODB_DIR}/tmp"

# ── Download db-ip Lite Country CSV ──────────────────────────────
DOWNLOAD_GZ="${GEODB_DIR}/tmp/dbip-country-lite.csv.gz"
CSV_FILE="${GEODB_DIR}/tmp/dbip-country-lite.csv"

log "Downloading db-ip Lite Country (${DBIP_MONTH})..."
curl -sSf -o "${DOWNLOAD_GZ}" "${DOWNLOAD_URL}"

# ── Verify gzip integrity ────────────────────────────────────────
if ! gzip -t "${DOWNLOAD_GZ}" 2>/dev/null; then
  log "ERROR: Downloaded file failed gzip integrity check. Aborting."
  rm -f "${DOWNLOAD_GZ}"
  exit 1
fi

log "Gzip integrity verified"
gunzip -f "${DOWNLOAD_GZ}"

# Validate CSV structure (first row should have 3 comma-separated fields)
FIRST_LINE=$(head -1 "${CSV_FILE}")
FIELD_COUNT=$(echo "${FIRST_LINE}" | awk -F',' '{print NF}')
if [ "${FIELD_COUNT}" -ne 3 ]; then
  log "ERROR: Unexpected CSV format — expected 3 fields, got ${FIELD_COUNT}"
  exit 1
fi

TOTAL_ROWS=$(wc -l < "${CSV_FILE}" | tr -d ' ')
log "CSV validated: ${TOTAL_ROWS} rows, 3 fields"

# ── Extract CIDRs for blocked countries and merge into config ────
# db-ip format: ip_start,ip_end,country_code
# We filter for blocked countries, convert IP ranges to CIDRs,
# and merge into Pipelock's ssrf.blockRanges.
CIDRS_FILE="${GEODB_DIR}/tmp/blocked-cidrs.txt"

python3 -c "
import csv, ipaddress, sys, yaml

blocked_file = '${BLOCKED_COUNTRIES_FILE}'
csv_file = '${CSV_FILE}'
cidrs_file = '${CIDRS_FILE}'
base_path = '${BASE_CONFIG}'
out_path = '${MERGED_CONFIG}'

# Read blocked country codes
blocked = set()
with open(blocked_file) as f:
    for line in f:
        line = line.strip()
        if line and not line.startswith('#'):
            blocked.add(line.upper())

# Extract CIDRs from db-ip CSV for blocked countries
cidrs = []
counts = {c: 0 for c in blocked}

with open(csv_file, newline='') as f:
    reader = csv.reader(f)
    for row in reader:
        if len(row) < 3:
            continue
        country = row[2].upper()
        if country not in blocked:
            continue
        try:
            start = ipaddress.ip_address(row[0])
            end = ipaddress.ip_address(row[1])
            for net in ipaddress.summarize_address_range(start, end):
                cidrs.append(str(net))
                counts[country] = counts.get(country, 0) + 1
        except (ValueError, TypeError):
            continue

# Report per-country counts
for country, count in sorted(counts.items()):
    if count > 0:
        print(f'  {country}: {count} CIDRs')

print(f'Total blocked CIDRs: {len(cidrs)}')

# Write CIDRs to file for audit trail
with open(cidrs_file, 'w') as f:
    for cidr in cidrs:
        f.write(cidr + '\n')

# Merge into Pipelock config
with open(base_path) as f:
    config = yaml.safe_load(f)

if 'ssrf' not in config:
    config['ssrf'] = {}
if 'blockRanges' not in config['ssrf']:
    config['ssrf']['blockRanges'] = []

existing = set(config['ssrf']['blockRanges'])
combined = sorted(existing | set(cidrs))
config['ssrf']['blockRanges'] = combined

with open(out_path, 'w') as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False, width=120)

print(f'Merged config: {len(existing)} base + {len(cidrs)} geo = {len(combined)} total block ranges')
" 2>&1 | while read -r line; do log "${line}"; done

# ── Archive for audit trail ─────────────────────────────────────
ARCHIVE_DIR="${GEODB_DIR}/archive"
mkdir -p "${ARCHIVE_DIR}"
TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)
cp "${CIDRS_FILE}" "${ARCHIVE_DIR}/blocked-cidrs-${TIMESTAMP}.txt"
echo "db-ip Lite Country ${DBIP_MONTH}" > "${ARCHIVE_DIR}/source-${TIMESTAMP}.txt"

# Keep only last 4 archives
ls -t "${ARCHIVE_DIR}"/blocked-cidrs-*.txt 2>/dev/null | tail -n +5 | xargs rm -f 2>/dev/null || true
ls -t "${ARCHIVE_DIR}"/source-*.txt 2>/dev/null | tail -n +5 | xargs rm -f 2>/dev/null || true

# ── Cleanup ─────────────────────────────────────────────────────
rm -rf "${GEODB_DIR}/tmp"

log "GeoIP refresh complete"
