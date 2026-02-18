#!/usr/bin/env bash
set -euo pipefail

# generate-squid-acls.sh — Extract blocking data from Pipelock's merged config
# and write Squid ACL files for domain and CIDR-level filtering.
#
# Called by entrypoint (initial boot) and cron (after each refresh cycle).
# After running this, call `squid -k reconfigure` to hot-reload ACLs.
#
# Outputs:
#   /etc/squid/acl-allowed-domains.txt  — api_allowlist (audit/reference only)
#   /etc/squid/acl-blocked-domains.txt  — threat feeds + hand-curated blocklist
#   /etc/squid/acl-blocked-cidrs.txt    — GeoIP CIDRs + SSRF ranges

MERGED_CONFIG="${MERGED_CONFIG:-/config/pipelock.yaml}"
ACL_DIR="/etc/squid"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] generate-squid-acls: $*"; }

if [ ! -f "${MERGED_CONFIG}" ]; then
  log "ERROR: ${MERGED_CONFIG} not found — cannot generate ACLs"
  exit 1
fi

mkdir -p "${ACL_DIR}"

python3 -c "
import yaml

config_path = '${MERGED_CONFIG}'
acl_dir = '${ACL_DIR}'

with open(config_path) as f:
    config = yaml.safe_load(f)

# ── Allowed domains (for reference/audit) ──────────────────────
allowed = config.get('api_allowlist', [])
with open(f'{acl_dir}/acl-allowed-domains.txt', 'w') as f:
    for domain in sorted(allowed):
        # Squid dstdomain format: .domain.com matches *.domain.com
        # Strip leading *. and add leading . for Squid subdomain matching
        d = domain.lstrip('*').lstrip('.')
        f.write(f'.{d}\n')
print(f'Allowed domains: {len(allowed)}')

# ── Blocked domains (threat feeds + hand-curated blocklist) ────
# Squid's dstdomain ACL rejects overlapping subdomains (e.g. .a.b.com
# when .b.com is already listed). We must prune: if a parent domain is
# in the set, all its subdomains are already covered and must be removed.
blocklist = config.get('fetch_proxy', {}).get('monitoring', {}).get('blocklist', [])
raw_domains = set()
for domain in blocklist:
    d = domain.lstrip('*').lstrip('.')
    if d:
        raw_domains.add(d)

print(f'Raw blocked domains: {len(raw_domains)}')

# Prune subdomains: sort by fewest labels first so parents are seen first
sorted_by_depth = sorted(raw_domains, key=lambda d: d.count('.'))
kept = set()
for d in sorted_by_depth:
    # Check if any parent domain is already in the kept set
    parts = d.split('.')
    is_subdomain = False
    for i in range(1, len(parts)):
        parent = '.'.join(parts[i:])
        if parent in kept:
            is_subdomain = True
            break
    if not is_subdomain:
        kept.add(d)

pruned = len(raw_domains) - len(kept)
print(f'Blocked domains: {len(kept)} (pruned {pruned} subdomain overlaps)')

with open(f'{acl_dir}/acl-blocked-domains.txt', 'w') as f:
    for domain in sorted(kept):
        f.write(f'.{domain}\n')

# ── Blocked CIDRs (GeoIP + SSRF internal ranges) ──────────────
# The 'internal' key contains both base SSRF ranges and GeoIP CIDRs
# (merged by refresh-geodb). We write them all — Squid also has
# hardcoded localnet ACLs for SSRF, but the file covers GeoIP.
internal = config.get('internal', [])
with open(f'{acl_dir}/acl-blocked-cidrs.txt', 'w') as f:
    for cidr in sorted(set(internal)):
        f.write(f'{cidr}\n')
print(f'Blocked CIDRs: {len(internal)}')
" 2>&1 | while read -r line; do log "${line}"; done

log "ACL files written to ${ACL_DIR}"
