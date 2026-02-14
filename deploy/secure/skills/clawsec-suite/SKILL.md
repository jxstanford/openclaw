---
name: clawsec-suite
description: "Cognitive-layer security for OpenClaw agents. Monitors workspace file integrity, runs scheduled security audits, and provides CVE/advisory feeds. Complements container isolation and network filtering."
metadata:
  {
    "openclaw":
      {
        "emoji": "🛡️",
        "requires": { "bins": ["sha256sum"] },
      },
  }
---

# ClawSec Security Suite

Cognitive-layer defense for OpenClaw agents. Three components:

1. **Soul Guardian** — File integrity monitoring for SOUL.md, IDENTITY.md, TOOLS.md
2. **Audit Watchdog** — Scheduled `openclaw security audit` runs with drift detection
3. **Security Feed** — CVE and advisory awareness for agent decision-making

## Soul Guardian

Monitors workspace identity files for unauthorized modifications. Run manually or via cron.

### Check file integrity

```bash
# Generate baseline hashes
cd "${WORKSPACE:-$HOME/.openclaw/workspace}"
sha256sum SOUL.md IDENTITY.md TOOLS.md USER.md AGENTS.md 2>/dev/null > .clawsec-baseline.sha256

# Verify integrity (returns non-zero on drift)
sha256sum --check .clawsec-baseline.sha256 --strict 2>&1
```

### Detect drift

```bash
# Compare current hashes to baseline
cd "${WORKSPACE:-$HOME/.openclaw/workspace}"
if ! sha256sum --check .clawsec-baseline.sha256 --strict --quiet 2>/dev/null; then
  echo "DRIFT DETECTED — workspace identity files modified since baseline"
  sha256sum --check .clawsec-baseline.sha256 2>&1 | grep -v ": OK$"
else
  echo "OK — all identity files match baseline"
fi
```

### Refresh baseline after approved changes

```bash
cd "${WORKSPACE:-$HOME/.openclaw/workspace}"
sha256sum SOUL.md IDENTITY.md TOOLS.md USER.md AGENTS.md 2>/dev/null > .clawsec-baseline.sha256
echo "Baseline updated at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

## Audit Watchdog

Runs the built-in security audit on schedule.

### Run security audit

```bash
# Full audit with deep gateway probe
openclaw security audit --deep --json 2>/dev/null || openclaw security audit --json

# Quick audit (no gateway probe)
openclaw security audit --json
```

### Interpret results

The audit returns JSON with findings at severity levels: `critical`, `warn`, `info`. Summarize critical and warn findings for the user. Suggest `--fix` for auto-remediable issues.

```bash
# Auto-fix safe issues
openclaw security audit --fix
```

## Security Feed

When asked about security or when reviewing tool/skill installations, consider:

- **Skill supply chain**: Verify skills from ClawHub have valid SHA256 checksums before installation
- **Dependency audits**: Run `npm audit` or `pnpm audit` in workspace projects
- **Container image updates**: Check for base image security patches periodically

### Check skill integrity

```bash
# List installed skills and verify checksums
ls -la "${HOME}/.openclaw/skills/" 2>/dev/null
ls -la "${WORKSPACE}/skills/" 2>/dev/null
```

## Opt-out: Clawtributor

Community reporting (clawtributor) is disabled by default. This suite operates locally only — no telemetry, no external reporting.

## Cron Integration

To schedule automated security checks, add cron jobs via the gateway:

```bash
# Daily security audit at 3am
openclaw cron add \
  --name "clawsec-audit" \
  --cron "0 3 * * *" \
  --tz "America/Los_Angeles" \
  --session isolated \
  --message "Run security audit: openclaw security audit --deep --json. Report any critical or warn findings." \
  --announce

# Hourly soul-guardian integrity check
openclaw cron add \
  --name "clawsec-soul-guardian" \
  --cron "0 * * * *" \
  --session isolated \
  --message "Check workspace file integrity: cd workspace && sha256sum --check .clawsec-baseline.sha256 --strict 2>&1. Report any drift immediately."
```
