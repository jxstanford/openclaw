#!/usr/bin/env bash
set -euo pipefail

# refresh-threats.sh — Download threat intelligence feeds, extract domains,
# and merge into Pipelock's fetch_proxy.monitoring.blocklist.
#
# Feeds:
#   1. HaGeZi TIF           — curated threat intelligence (~670K domains)
#   2. urlhaus-filter        — active malware distribution domains
#   3. phishing-filter       — active phishing domains
#
# Runs after refresh-geodb: reads MERGED_CONFIG (geodb output), writes back
# to MERGED_CONFIG with the blocklist expanded.  Preserves hand-curated
# entries from BASE_CONFIG.
#
# Each feed is downloaded independently — a failed download falls back to
# its cached copy so one upstream outage doesn't wipe the whole list.

THREATS_DIR="${THREATS_DIR:-/var/lib/threatfeeds}"
BASE_CONFIG="${BASE_CONFIG:-/config/pipelock-base.yaml}"
MERGED_CONFIG="${MERGED_CONFIG:-/config/pipelock.yaml}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

# ── Feed URLs ────────────────────────────────────────────────────
FEED_HAGEZI="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/tif.txt"
FEED_URLHAUS="https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-domains-online.txt"
FEED_PHISHING="https://malware-filter.gitlab.io/malware-filter/phishing-filter-domains.txt"

# ── Validate prerequisites ───────────────────────────────────────
if [ ! -f "${MERGED_CONFIG}" ]; then
  log "ERROR: ${MERGED_CONFIG} not found (run refresh-geodb first)"
  exit 1
fi

mkdir -p "${THREATS_DIR}/tmp" "${THREATS_DIR}/cache"

# ── Download a single feed with cache fallback ───────────────────
download_feed() {
  local name="$1" url="$2" outfile="$3"
  local cache="${THREATS_DIR}/cache/${name}.txt"

  log "Downloading ${name}..."
  if curl -sSf --max-time 60 -o "${outfile}" "${url}"; then
    # Validate: must be non-empty and contain >10 domain-like lines
    local valid_lines
    valid_lines=$(grep -cE '^[a-zA-Z0-9]' "${outfile}" 2>/dev/null || echo "0")
    if [ "${valid_lines}" -gt 10 ]; then
      log "  ${name}: ${valid_lines} domains downloaded"
      cp "${outfile}" "${cache}"
      return 0
    else
      log "  WARN: ${name} has only ${valid_lines} valid lines — using cache"
    fi
  else
    log "  WARN: ${name} download failed — using cache"
  fi

  # Fall back to cache
  if [ -f "${cache}" ]; then
    local cached_lines
    cached_lines=$(grep -cE '^[a-zA-Z0-9]' "${cache}" 2>/dev/null || echo "0")
    log "  ${name}: using cached data (${cached_lines} domains)"
    cp "${cache}" "${outfile}"
    return 0
  else
    log "  ${name}: no cache available — skipping"
    : > "${outfile}"
    return 0
  fi
}

# ── Download all feeds ───────────────────────────────────────────
download_feed "hagezi-tif" "${FEED_HAGEZI}"  "${THREATS_DIR}/tmp/hagezi.txt"
download_feed "urlhaus-filter"    "${FEED_URLHAUS}" "${THREATS_DIR}/tmp/urlhaus.txt"
download_feed "phishing-filter"   "${FEED_PHISHING}" "${THREATS_DIR}/tmp/phishing.txt"

# ── Merge feeds + hand-curated entries into blocklist ────────────
python3 -c "
import yaml, sys

base_path = '${BASE_CONFIG}'
merged_path = '${MERGED_CONFIG}'
tmp_dir = '${THREATS_DIR}/tmp'

feed_files = [
    ('hagezi-tif', f'{tmp_dir}/hagezi.txt'),
    ('urlhaus-filter',    f'{tmp_dir}/urlhaus.txt'),
    ('phishing-filter',   f'{tmp_dir}/phishing.txt'),
]

# Read hand-curated blocklist entries from the base config
with open(base_path) as f:
    base = yaml.safe_load(f)

hand_curated = set(base.get('fetch_proxy', {}).get('monitoring', {}).get('blocklist', []))
print(f'Hand-curated entries: {len(hand_curated)}')

# Parse domains from feed files (skip comments, blanks)
feed_domains = set()
for name, path in feed_files:
    count = 0
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#') or line.startswith('!'):
                    continue
                # Extract bare domain (some feeds have comments after domain)
                domain = line.split()[0].lower()
                # Skip IP addresses and non-domain entries
                if not domain or domain[0].isdigit() or '.' not in domain:
                    continue
                # Normalize to *.domain.com glob format
                if not domain.startswith('*.'):
                    domain = f'*.{domain}'
                feed_domains.add(domain)
                count += 1
    except FileNotFoundError:
        pass
    print(f'  {name}: {count} domains')

print(f'Total feed domains: {len(feed_domains)}')

# Merge: hand-curated + feed domains
combined = sorted(hand_curated | feed_domains)
print(f'Merged blocklist: {len(hand_curated)} hand-curated + {len(feed_domains)} feed = {len(combined)} total')

# Read current merged config (has geodb changes) and update blocklist
with open(merged_path) as f:
    config = yaml.safe_load(f)

config.setdefault('fetch_proxy', {}).setdefault('monitoring', {})['blocklist'] = combined

with open(merged_path, 'w') as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False, width=120)

print(f'Wrote {len(combined)} blocklist entries to {merged_path}')
" 2>&1 | while read -r line; do log "${line}"; done

# ── Archive for audit trail ──────────────────────────────────────
ARCHIVE_DIR="${THREATS_DIR}/archive"
mkdir -p "${ARCHIVE_DIR}"
TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)

# Write summary
python3 -c "
import yaml
with open('${MERGED_CONFIG}') as f:
    config = yaml.safe_load(f)
blocklist = config.get('fetch_proxy', {}).get('monitoring', {}).get('blocklist', [])
print(f'Total blocklist entries: {len(blocklist)}')
print(f'Timestamp: ${TIMESTAMP}')
print(f'Feeds: hagezi-tif, urlhaus-filter, phishing-filter')
" > "${ARCHIVE_DIR}/threats-summary-${TIMESTAMP}.txt"

# Keep only last 7 archives
ls -t "${ARCHIVE_DIR}"/threats-summary-*.txt 2>/dev/null | tail -n +8 | xargs rm -f 2>/dev/null || true

# ── Cleanup ──────────────────────────────────────────────────────
rm -rf "${THREATS_DIR}/tmp"

log "Threat feed refresh complete"
