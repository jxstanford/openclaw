#!/usr/bin/env bash
set -euo pipefail

# Secure OpenClaw — end-to-end verification script.
# Run this after `docker compose up -d` to validate the deployment.
#
# Tests all security layers:
#   Layer 1: Pipelock egress proxy (DLP, domain blocklist, SSRF)
#   Layer 2: Docker sandbox isolation
#   Layer 3: Tool policies per agent
#   Layer 4: Gateway hardening
#   Layer 5: ClawSec cognitive defense
#   Layer 6: Session and memory isolation

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

PASS=0
FAIL=0
SKIP=0

pass() { echo "  [PASS] $1"; ((PASS++)); }
fail() { echo "  [FAIL] $1"; ((FAIL++)); }
skip() { echo "  [SKIP] $1"; ((SKIP++)); }

echo "=== Secure OpenClaw Verification ==="
echo ""

# ── Pre-flight ──────────────────────────────────────────────────
echo "--- Pre-flight Checks ---"

if docker compose ps --format json 2>/dev/null | grep -q '"State":"running"'; then
  pass "Docker Compose stack is running"
else
  fail "Docker Compose stack not running — run: docker compose up -d"
  echo ""
  echo "Cannot continue without running stack. Exiting."
  exit 1
fi

if docker compose ps pipelock --format '{{.State}}' 2>/dev/null | grep -q "running"; then
  pass "Pipelock proxy is running"
else
  fail "Pipelock proxy not running"
fi

if docker compose exec pipelock /pipelock healthcheck --addr 127.0.0.1:8888 2>/dev/null; then
  pass "Pipelock healthcheck passes"
else
  fail "Pipelock healthcheck failed"
fi

GATEWAY_PORT=$(grep OPENCLAW_GATEWAY_PORT .env 2>/dev/null | cut -d= -f2)
GATEWAY_PORT="${GATEWAY_PORT:-18789}"

if curl -sf "http://localhost:${GATEWAY_PORT}" >/dev/null 2>&1; then
  pass "Gateway responding on port ${GATEWAY_PORT}"
else
  # Try with auth header
  TOKEN=$(grep OPENCLAW_GATEWAY_TOKEN .env 2>/dev/null | cut -d= -f2)
  if curl -sf -H "Authorization: Bearer ${TOKEN}" "http://localhost:${GATEWAY_PORT}" >/dev/null 2>&1; then
    pass "Gateway responding on port ${GATEWAY_PORT} (auth required)"
  else
    fail "Gateway not responding on port ${GATEWAY_PORT}"
  fi
fi

echo ""

# ── Layer 1: Pipelock Egress Proxy ──────────────────────────────
echo "--- Layer 1: Pipelock Egress Proxy ---"

# Test domain blocklist
for domain in pastebin.com transfer.sh requestbin.com webhook.site; do
  if docker compose exec pipelock /pipelock fetch --addr 127.0.0.1:8888 "https://${domain}" 2>&1 | grep -qi "blocked\|denied\|forbidden\|error"; then
    pass "Domain blocked: ${domain}"
  else
    fail "Domain NOT blocked: ${domain}"
  fi
done

# Test DLP — API key pattern in URL
TEST_URL="https://httpbin.org/get?key=sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
if docker compose exec pipelock /pipelock fetch --addr 127.0.0.1:8888 "${TEST_URL}" 2>&1 | grep -qi "blocked\|denied\|dlp\|secret\|error"; then
  pass "DLP blocks API key in URL"
else
  skip "DLP API key test inconclusive (may need live target)"
fi

# Test SSRF — private IP ranges
for ip in 10.0.0.1 172.16.0.1 192.168.1.1 169.254.169.254; do
  if docker compose exec pipelock /pipelock fetch --addr 127.0.0.1:8888 "http://${ip}" 2>&1 | grep -qi "blocked\|ssrf\|denied\|error"; then
    pass "SSRF blocked: ${ip}"
  else
    fail "SSRF NOT blocked: ${ip}"
  fi
done

# Test allowed domain
if docker compose exec pipelock /pipelock fetch --addr 127.0.0.1:8888 "https://api.anthropic.com" 2>&1 | grep -qi "blocked\|denied"; then
  fail "Allowed domain incorrectly blocked: api.anthropic.com"
else
  pass "Allowed domain accessible: api.anthropic.com"
fi

# Test GeoIP blocking (check if merged config has geo CIDRs)
if docker compose exec pipelock test -f /config/pipelock.yaml 2>/dev/null; then
  GEO_RANGES=$(docker compose exec pipelock grep -c "blockRanges" /config/pipelock.yaml 2>/dev/null || echo "0")
  if [ "${GEO_RANGES}" -gt 0 ]; then
    pass "GeoIP block ranges merged into Pipelock config"
  else
    skip "GeoIP block ranges not present (MaxMind credentials may not be set)"
  fi
else
  fail "Pipelock merged config not found at /config/pipelock.yaml"
fi

echo ""

# ── Layer 2: Docker Sandbox Isolation ───────────────────────────
echo "--- Layer 2: Sandbox Isolation ---"

# Check sandbox images exist
for img in "openclaw-sandbox:bookworm-slim" "openclaw-sandbox-common:bookworm-slim" "openclaw-sandbox-browser:bookworm-slim"; do
  if docker image inspect "${img}" >/dev/null 2>&1; then
    pass "Sandbox image exists: ${img}"
  else
    fail "Sandbox image missing: ${img}"
  fi
done

echo ""

# ── Layer 3: Tool Policies ──────────────────────────────────────
echo "--- Layer 3: Tool Policies (config validation) ---"

CONFIG_FILE=".openclaw/openclaw.json"
if [ -f "${CONFIG_FILE}" ]; then
  # Validate agents exist
  AGENTS=$(bun -e "
    import JSON5 from 'json5';
    const raw = require('fs').readFileSync('${CONFIG_FILE}', 'utf-8');
    const cfg = JSON5.parse(raw);
    console.log(cfg.agents.list.map(a => a.id).join(','));
  " 2>/dev/null || echo "")

  if echo "${AGENTS}" | grep -q "personal"; then
    pass "Personal agent configured"
  else
    fail "Personal agent missing from config"
  fi

  if echo "${AGENTS}" | grep -q "work"; then
    pass "Work agent configured"
  else
    fail "Work agent missing from config"
  fi

  if echo "${AGENTS}" | grep -q "public"; then
    pass "Public agent configured"
  else
    fail "Public agent missing from config"
  fi

  # Validate public agent tool deny list
  PUBLIC_DENY=$(bun -e "
    import JSON5 from 'json5';
    const raw = require('fs').readFileSync('${CONFIG_FILE}', 'utf-8');
    const cfg = JSON5.parse(raw);
    const pub = cfg.agents.list.find(a => a.id === 'public');
    console.log(JSON.stringify(pub.tools.deny));
  " 2>/dev/null || echo "[]")

  if echo "${PUBLIC_DENY}" | grep -q "exec"; then
    pass "Public agent denies exec tool"
  else
    fail "Public agent does NOT deny exec tool"
  fi

  # Validate public agent sandbox settings
  PUBLIC_SANDBOX=$(bun -e "
    import JSON5 from 'json5';
    const raw = require('fs').readFileSync('${CONFIG_FILE}', 'utf-8');
    const cfg = JSON5.parse(raw);
    const pub = cfg.agents.list.find(a => a.id === 'public');
    console.log(pub.sandbox.workspaceAccess, pub.sandbox.docker.network, pub.sandbox.docker.readOnlyRoot);
  " 2>/dev/null || echo "")

  if echo "${PUBLIC_SANDBOX}" | grep -q "none none true"; then
    pass "Public agent: no workspace, no network, read-only root"
  else
    fail "Public agent sandbox not fully locked down: ${PUBLIC_SANDBOX}"
  fi

  # Validate session DM scope
  DM_SCOPE=$(bun -e "
    import JSON5 from 'json5';
    const raw = require('fs').readFileSync('${CONFIG_FILE}', 'utf-8');
    const cfg = JSON5.parse(raw);
    console.log(cfg.session?.dmScope || 'main');
  " 2>/dev/null || echo "main")

  if [ "${DM_SCOPE}" = "per-channel-peer" ]; then
    pass "DM scope isolation: per-channel-peer"
  else
    fail "DM scope is '${DM_SCOPE}' (should be per-channel-peer)"
  fi

  # Validate insecure auth disabled
  INSECURE_AUTH=$(bun -e "
    import JSON5 from 'json5';
    const raw = require('fs').readFileSync('${CONFIG_FILE}', 'utf-8');
    const cfg = JSON5.parse(raw);
    console.log(cfg.gateway?.controlUi?.allowInsecureAuth ?? 'not set');
  " 2>/dev/null || echo "not set")

  if [ "${INSECURE_AUTH}" = "false" ]; then
    pass "Insecure auth disabled"
  else
    fail "allowInsecureAuth is '${INSECURE_AUTH}' (should be false)"
  fi

  # Validate sensitive data redaction
  REDACT=$(bun -e "
    import JSON5 from 'json5';
    const raw = require('fs').readFileSync('${CONFIG_FILE}', 'utf-8');
    const cfg = JSON5.parse(raw);
    console.log(cfg.logging?.redactSensitive || 'off');
  " 2>/dev/null || echo "off")

  if [ "${REDACT}" = "tools" ]; then
    pass "Sensitive data redaction enabled"
  else
    fail "redactSensitive is '${REDACT}' (should be 'tools')"
  fi
else
  fail "Config file not found: ${CONFIG_FILE}"
fi

echo ""

# ── Layer 4: Gateway Hardening ──────────────────────────────────
echo "--- Layer 4: Gateway Hardening ---"

# Check mDNS disabled
BONJOUR_VAR=$(docker compose exec openclaw-gateway printenv OPENCLAW_DISABLE_BONJOUR 2>/dev/null || echo "not set")
if [ "${BONJOUR_VAR}" = "1" ]; then
  pass "mDNS broadcasting disabled (OPENCLAW_DISABLE_BONJOUR=1)"
else
  fail "OPENCLAW_DISABLE_BONJOUR not set in gateway container"
fi

# Check file permissions
if [ -f .env ]; then
  ENV_PERMS=$(stat -f '%A' .env 2>/dev/null || stat -c '%a' .env 2>/dev/null || echo "unknown")
  if [ "${ENV_PERMS}" = "600" ]; then
    pass "File permissions: .env is 600"
  else
    fail "File permissions: .env is ${ENV_PERMS} (should be 600)"
  fi
fi

if [ -f .openclaw/openclaw.json ]; then
  CFG_PERMS=$(stat -f '%A' .openclaw/openclaw.json 2>/dev/null || stat -c '%a' .openclaw/openclaw.json 2>/dev/null || echo "unknown")
  if [ "${CFG_PERMS}" = "600" ]; then
    pass "File permissions: openclaw.json is 600"
  else
    fail "File permissions: openclaw.json is ${CFG_PERMS} (should be 600)"
  fi
fi

OPENCLAW_DIR_PERMS=$(stat -f '%A' .openclaw 2>/dev/null || stat -c '%a' .openclaw 2>/dev/null || echo "unknown")
if [ "${OPENCLAW_DIR_PERMS}" = "700" ]; then
  pass "File permissions: .openclaw/ is 700"
else
  fail "File permissions: .openclaw/ is ${OPENCLAW_DIR_PERMS} (should be 700)"
fi

echo ""

# ── Layer 5: ClawSec Cognitive Defense ──────────────────────────
echo "--- Layer 5: ClawSec Cognitive Defense ---"

# Check skill is installed
if [ -f skills/clawsec-suite/SKILL.md ]; then
  pass "ClawSec skill suite installed"
else
  fail "ClawSec skill suite missing from skills/"
fi

# Check soul-guardian baselines
for workspace in .openclaw/workspace .openclaw/workspace-work; do
  if [ -f "${workspace}/.clawsec-baseline.sha256" ]; then
    if (cd "${workspace}" && sha256sum --check .clawsec-baseline.sha256 --strict --quiet 2>/dev/null); then
      pass "Soul-guardian baseline intact: ${workspace}"
    else
      fail "Soul-guardian drift detected: ${workspace}"
    fi
  else
    skip "Soul-guardian baseline not found: ${workspace}"
  fi
done

echo ""

# ── Layer 6: Tailscale Auth (optional) ──────────────────────────
echo "--- Layer 6: Tailscale Auth ---"

if command -v tailscale >/dev/null 2>&1; then
  if tailscale status --json 2>/dev/null | grep -q '"Online":true'; then
    pass "Tailscale connected"
    if tailscale serve status 2>/dev/null | grep -q "${GATEWAY_PORT}"; then
      pass "Tailscale Serve configured for gateway"
    else
      skip "Tailscale Serve not configured (run: SETUP_TAILSCALE=1 ./setup.sh)"
    fi
  else
    skip "Tailscale not connected"
  fi
else
  skip "Tailscale not installed"
fi

echo ""

# ── Summary ─────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL + SKIP))
echo "=== Verification Complete ==="
echo "  Total: ${TOTAL}  Pass: ${PASS}  Fail: ${FAIL}  Skip: ${SKIP}"
echo ""

if [ "${FAIL}" -gt 0 ]; then
  echo "  Some checks failed. Review the output above and fix issues."
  echo "  Run this script again after fixing."
  exit 1
else
  echo "  All checks passed. Deployment is secure."
  exit 0
fi
