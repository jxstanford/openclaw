# Secure OpenClaw Deployment

Containerized OpenClaw deployment with defense-in-depth security across six layers.

## Quick Start

```bash
cp .env.example .env                           # fill in secrets
cp openclaw.example.json .openclaw/openclaw.json   # configure agents
bash setup.sh                                  # first-time setup
docker compose up -d                           # start the stack
bash verify.sh                                 # validate all layers
```

## Architecture

```
  Internet
     │
     ▼
┌─────────┐      ┌──────────────────┐      ┌─────────────────────┐
│ Tailscale│─────▶│ OpenClaw Gateway │─────▶│  Docker Sandboxes   │
│  Serve   │ L6   │  (control plane) │  L2   │  (code execution)   │
│  (HTTPS) │      │  L3 L4 L5       │      │                     │
└─────────┘      └────────┬─────────┘      └──────────┬──────────┘
                          │                            │
                          ▼                            ▼
                 ┌─────────────────┐          ┌────────────────┐
                 │    Pipelock     │          │   Pipelock     │
                 │  (egress proxy) │          │ (egress proxy) │
                 │  L1: DLP, SSRF  │          │ L1: DLP, SSRF  │
                 │  blocklist, geo │          │ blocklist, geo │
                 └────────┬────────┘          └───────┬────────┘
                          │                           │
                          ▼                           ▼
                      Internet                    Internet
```

All outbound traffic from both the gateway and sandboxes routes through
Pipelock. The gateway serves the Control UI and WebSocket API, protected
by token auth and optionally Tailscale identity.

## Security Layers

### Layer 1 -- Pipelock Egress Proxy

All outbound HTTP from the gateway routes through Pipelock, which enforces
domain blocklists (blocks known malware/tracking domains), DLP patterns
(prevents accidental leakage of API keys, tokens, credentials in requests),
SSRF protection (blocks requests to private/internal IP ranges), GeoIP
country-level blocking (denies traffic to sanctioned countries like NK, Iran,
Cuba, Syria), and automated threat intelligence feeds (daily-refreshed
blocklists from community-maintained threat databases).

**Config:** `pipelock.yaml`, `proxy/geo-blocked-countries.conf`

#### Threat Intelligence Feeds

The proxy automatically aggregates three external threat intelligence feeds
into the domain blocklist, refreshed daily at 04:00 UTC via cron. Hand-curated
entries from `pipelock.yaml` are always preserved.

| Feed | Source | Content |
|------|--------|---------|
| HaGeZi TIF | [GitHub](https://github.com/hagezi/dns-blocklists) | Curated threat intelligence — C2, malware, phishing (~670K domains) |
| urlhaus-filter | [GitLab Pages](https://malware-filter.gitlab.io/malware-filter/) | Active malware distribution domains (URLhaus data) |
| phishing-filter | [GitLab Pages](https://malware-filter.gitlab.io/malware-filter/) | Active phishing domains |

Each feed downloads independently with per-feed cache fallback — a single
upstream outage won't remove protection from the other feeds. Pipelock
requires a container restart to reload the merged config (same as GeoIP).

### Layer 2 -- Docker Sandbox Isolation

Agent code execution (shell commands, scripts) runs inside throwaway Docker
containers rather than on the host. The gateway spawns sandboxes from a
locked-down image with no network access except through Pipelock, preventing
a prompt-injected agent from touching the host filesystem or making unproxied
network calls.

**Config:** `docker-compose.yml` (network topology), sandbox images

### Layer 3 -- Tool Policies

Each agent profile (personal, work, public) has an explicit allowlist of
tools it can invoke and configurable limits (max file size, execution
timeout). The "public" agent, for example, has no exec/file/browser tools
at all, while "work" has a constrained set -- preventing prompt injection
from escalating an agent's capabilities beyond its role.

**Config:** `.openclaw/openclaw.json` (`agents.list[].tools`)

### Layer 4 -- Gateway Hardening

The gateway disables mDNS/Bonjour broadcasting (so it doesn't advertise
itself on the network), requires token-based authentication for all
WebSocket connections, binds to LAN rather than public interfaces, and
enforces permission boundaries so the Control UI can't bypass auth.

**Config:** `.openclaw/openclaw.json` (`gateway`), `.env` (`OPENCLAW_DISABLE_BONJOUR`)

### Layer 5 -- ClawSec Cognitive Defense

Custom skills loaded into the agent's system prompt that detect and resist
prompt injection, social engineering, and instruction override attempts at
the LLM reasoning level. These include baseline integrity checks (agent
won't deviate from its defined persona), jailbreak pattern recognition,
and guardrails against revealing system prompts or config secrets.

**Config:** `skills/clawsec-suite/`

### Layer 6 -- Tailscale Identity Auth

When enabled, wraps the gateway in Tailscale Serve (HTTPS with WireGuard
encryption), restricting access to authenticated devices on your tailnet.
Provides identity-based access control -- only your verified devices can
reach the gateway -- and enables WebCrypto device pairing as an additional
layer over token auth.

**Setup:** `tailscale serve --bg http://localhost:18789` (host-level, not in Docker)

## Verification

Run `bash verify.sh` after deployment. It tests each layer end-to-end:

- Pipelock blocklist, DLP, SSRF, and GeoIP rejection
- Sandbox image existence
- Agent tool policy validation
- Gateway auth and hardening flags
- ClawSec skill integrity baselines
- Tailscale connection status

## Channel Setup

### Signal

Signal runs as a separate `signal-cli` container (`linux/amd64`, Rosetta on
Apple Silicon). Uses signal-cli's native HTTP daemon on port 8080.

```bash
# Register a dedicated bot number
docker compose --profile signal run --rm -e SIGNAL_MODE=register signal-cli

# After verification, switch to daemon mode
# Set SIGNAL_MODE=daemon in .env, then:
docker compose --profile signal up -d signal-cli
```

OpenClaw connects to the daemon at `http://signal-cli:8080` (external
daemon mode, `autoStart: false`).

### Slack

Requires a Slack App with Socket Mode:
1. Create app at https://api.slack.com/apps
2. Enable Socket Mode, generate App-Level Token (`xapp-...`)
3. Add bot scopes: `app_mentions:read`, `channels:history`, `chat:write`, etc.
4. Subscribe to bot events: `message.im`, `app_mention`, etc.
5. Install to workspace, copy Bot Token (`xoxb-...`)
6. Set `SLACK_BOT_TOKEN` and `SLACK_APP_TOKEN` in `.env`

## Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Service definitions and network topology |
| `pipelock.yaml` | Egress proxy policy (DLP, blocklist, SSRF) |
| `.env.example` | Environment variable template |
| `openclaw.example.json` | Gateway and agent config template |
| `setup.sh` | First-time deployment setup |
| `verify.sh` | End-to-end security verification |
| `proxy/` | Pipelock custom image (GeoIP + threat feeds) |
| `proxy/refresh-threats.sh` | Threat intelligence feed aggregation script |
| `signal/` | signal-cli daemon image |
| `skills/` | ClawSec cognitive defense skills |
