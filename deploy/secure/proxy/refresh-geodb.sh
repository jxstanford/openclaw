#!/usr/bin/env bash
set -euo pipefail

# refresh-geodb.sh — Download MaxMind GeoLite2-Country CSV, verify integrity,
# extract CIDRs for blocked countries, and merge into Pipelock config.
#
# Requires: MAXMIND_ACCOUNT_ID and MAXMIND_LICENSE_KEY env vars.
# Register free at: https://www.maxmind.com/en/geolite2/signup

GEODB_DIR="${GEODB_DIR:-/var/lib/geogate}"
BLOCKED_COUNTRIES_FILE="${BLOCKED_COUNTRIES_FILE:-/etc/geogate/blocked-countries.conf}"
BASE_CONFIG="${BASE_CONFIG:-/config/pipelock-base.yaml}"
MERGED_CONFIG="${MERGED_CONFIG:-/config/pipelock.yaml}"
MAXMIND_ACCOUNT_ID="${MAXMIND_ACCOUNT_ID:-}"
MAXMIND_LICENSE_KEY="${MAXMIND_LICENSE_KEY:-}"

DOWNLOAD_BASE="https://download.maxmind.com/geoip/databases/GeoLite2-Country-CSV/download"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

# ── Validate prerequisites ─────────────────────────────────────
if [ -z "${MAXMIND_ACCOUNT_ID}" ] || [ -z "${MAXMIND_LICENSE_KEY}" ]; then
  log "WARN: MAXMIND_ACCOUNT_ID or MAXMIND_LICENSE_KEY not set — skipping GeoIP refresh"
  log "Register free at: https://www.maxmind.com/en/geolite2/signup"
  # If no GeoIP configured, just copy base config as-is
  if [ -f "${BASE_CONFIG}" ] && [ ! -f "${MERGED_CONFIG}" ]; then
    cp "${BASE_CONFIG}" "${MERGED_CONFIG}"
  fi
  exit 0
fi

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

# ── Download GeoLite2-Country-CSV ───────────────────────────────
DOWNLOAD_ZIP="${GEODB_DIR}/tmp/GeoLite2-Country-CSV.zip"
DOWNLOAD_SHA="${GEODB_DIR}/tmp/GeoLite2-Country-CSV.zip.sha256"
AUTH_HEADER="$(echo -n "${MAXMIND_ACCOUNT_ID}:${MAXMIND_LICENSE_KEY}" | base64)"

log "Downloading GeoLite2-Country-CSV..."
curl -sSf \
  -H "Authorization: Basic ${AUTH_HEADER}" \
  -o "${DOWNLOAD_ZIP}" \
  "${DOWNLOAD_BASE}?suffix=zip"

log "Downloading SHA256 checksum..."
curl -sSf \
  -H "Authorization: Basic ${AUTH_HEADER}" \
  -o "${DOWNLOAD_SHA}" \
  "${DOWNLOAD_BASE}?suffix=zip.sha256"

# ── Verify SHA256 checksum ──────────────────────────────────────
EXPECTED_SHA=$(awk '{print $1}' "${DOWNLOAD_SHA}")
ACTUAL_SHA=$(sha256sum "${DOWNLOAD_ZIP}" | awk '{print $1}')

if [ "${EXPECTED_SHA}" != "${ACTUAL_SHA}" ]; then
  log "ERROR: SHA256 verification FAILED"
  log "  Expected: ${EXPECTED_SHA}"
  log "  Got:      ${ACTUAL_SHA}"
  log "  Possible tampering or corrupted download. Aborting."
  rm -f "${DOWNLOAD_ZIP}" "${DOWNLOAD_SHA}"
  exit 1
fi

log "SHA256 verified: ${ACTUAL_SHA}"

# ── Extract CSV files ───────────────────────────────────────────
EXTRACT_DIR="${GEODB_DIR}/tmp/extract"
rm -rf "${EXTRACT_DIR}"
mkdir -p "${EXTRACT_DIR}"
unzip -q -o "${DOWNLOAD_ZIP}" -d "${EXTRACT_DIR}"

# Find the versioned directory (e.g., GeoLite2-Country-CSV_20260101)
CSV_DIR=$(find "${EXTRACT_DIR}" -maxdepth 1 -type d -name "GeoLite2-Country-CSV_*" | head -1)

if [ -z "${CSV_DIR}" ]; then
  log "ERROR: Could not find GeoLite2-Country-CSV directory in archive"
  exit 1
fi

LOCATIONS_FILE="${CSV_DIR}/GeoLite2-Country-Locations-en.csv"
BLOCKS_V4_FILE="${CSV_DIR}/GeoLite2-Country-Blocks-IPv4.csv"
BLOCKS_V6_FILE="${CSV_DIR}/GeoLite2-Country-Blocks-IPv6.csv"

for f in "${LOCATIONS_FILE}" "${BLOCKS_V4_FILE}" "${BLOCKS_V6_FILE}"; do
  if [ ! -f "${f}" ]; then
    log "ERROR: Expected file not found: ${f}"
    exit 1
  fi
done

# ── Extract CIDRs for blocked countries ─────────────────────────
CIDRS_FILE="${GEODB_DIR}/tmp/blocked-cidrs.txt"
> "${CIDRS_FILE}"

for COUNTRY in "${BLOCKED_CODES[@]}"; do
  # Get geoname_id(s) for this country from the locations CSV
  # CSV format: geoname_id,locale_code,continent_code,continent_name,country_iso_code,country_name,...
  GEONAME_IDS=$(awk -F',' -v code="${COUNTRY}" '$5 == code {print $1}' "${LOCATIONS_FILE}")

  if [ -z "${GEONAME_IDS}" ]; then
    log "WARN: No geoname_id found for country code: ${COUNTRY}"
    continue
  fi

  COUNT=0
  for GEONAME_ID in ${GEONAME_IDS}; do
    # IPv4 blocks: network,geoname_id,registered_country_geoname_id,...
    # Match on both geoname_id (col 2) and registered_country_geoname_id (col 3)
    awk -F',' -v gid="${GEONAME_ID}" '($2 == gid || $3 == gid) {print $1}' "${BLOCKS_V4_FILE}" >> "${CIDRS_FILE}"
    V4=$(awk -F',' -v gid="${GEONAME_ID}" '($2 == gid || $3 == gid) {print $1}' "${BLOCKS_V4_FILE}" | wc -l)

    # IPv6 blocks
    awk -F',' -v gid="${GEONAME_ID}" '($2 == gid || $3 == gid) {print $1}' "${BLOCKS_V6_FILE}" >> "${CIDRS_FILE}"
    V6=$(awk -F',' -v gid="${GEONAME_ID}" '($2 == gid || $3 == gid) {print $1}' "${BLOCKS_V6_FILE}" | wc -l)

    COUNT=$((COUNT + V4 + V6))
  done

  log "  ${COUNTRY}: ${COUNT} CIDRs"
done

TOTAL_CIDRS=$(wc -l < "${CIDRS_FILE}" | tr -d ' ')
log "Total blocked CIDRs: ${TOTAL_CIDRS}"

# ── Merge CIDRs into Pipelock config ───────────────────────────
# Generate YAML array entries for ssrf.blockRanges
GEO_YAML="${GEODB_DIR}/tmp/geo-block-ranges.yaml"
{
  echo "# Auto-generated GeoIP block ranges — do not edit manually"
  echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# Countries: ${BLOCKED_CODES[*]}"
  echo "# Total CIDRs: ${TOTAL_CIDRS}"
  while IFS= read -r cidr; do
    echo "      - \"${cidr}\""
  done < "${CIDRS_FILE}"
} > "${GEO_YAML}"

# Merge: insert geo block ranges into the base config's ssrf.blockRanges
# Strategy: find the ssrf.blockRanges section in base config and append geo CIDRs
python3 -c "
import sys, yaml, os

base_path = '${BASE_CONFIG}'
geo_cidrs_path = '${CIDRS_FILE}'
out_path = '${MERGED_CONFIG}'

with open(base_path) as f:
    config = yaml.safe_load(f)

with open(geo_cidrs_path) as f:
    geo_cidrs = [line.strip() for line in f if line.strip()]

# Ensure ssrf.blockRanges exists
if 'ssrf' not in config:
    config['ssrf'] = {}
if 'blockRanges' not in config['ssrf']:
    config['ssrf']['blockRanges'] = []

# Remove old geo entries (marked with comment prefix in the string is not possible in YAML,
# so we track them separately). Just append — dedup by converting to set.
existing = set(config['ssrf']['blockRanges'])
combined = list(existing | set(geo_cidrs))
combined.sort()
config['ssrf']['blockRanges'] = combined

with open(out_path, 'w') as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False, width=120)

print(f'Merged config: {len(existing)} base + {len(geo_cidrs)} geo = {len(combined)} total block ranges')
" 2>&1 | while read -r line; do log "${line}"; done

# ── Archive for audit trail ─────────────────────────────────────
ARCHIVE_DIR="${GEODB_DIR}/archive"
mkdir -p "${ARCHIVE_DIR}"
TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)
cp "${CIDRS_FILE}" "${ARCHIVE_DIR}/blocked-cidrs-${TIMESTAMP}.txt"
echo "${ACTUAL_SHA}  GeoLite2-Country-CSV.zip" > "${ARCHIVE_DIR}/sha256-${TIMESTAMP}.txt"

# Keep only last 4 archives
ls -t "${ARCHIVE_DIR}"/blocked-cidrs-*.txt 2>/dev/null | tail -n +5 | xargs rm -f 2>/dev/null || true
ls -t "${ARCHIVE_DIR}"/sha256-*.txt 2>/dev/null | tail -n +5 | xargs rm -f 2>/dev/null || true

# ── Cleanup ─────────────────────────────────────────────────────
rm -rf "${GEODB_DIR}/tmp"

log "GeoIP refresh complete"
