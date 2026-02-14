# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**See also: `AGENTS.md`** for detailed operational notes (VM ops, release workflows, multi-agent safety, NPM publishing).

## What is OpenClaw?

OpenClaw is a personal AI assistant gateway. It runs on your devices and routes messages between AI models and messaging channels (WhatsApp, Telegram, Slack, Discord, Signal, iMessage, Google Chat, Microsoft Teams, Matrix, Zalo, WebChat). The gateway is the control plane; the product is the assistant.

## Build & Development Commands

| Task | Command |
|------|---------|
| Install deps | `pnpm install` |
| Build | `pnpm build` |
| Full check (format + types + lint) | `pnpm check` |
| Format fix | `pnpm format` |
| Lint | `pnpm lint` |
| Lint + auto-fix | `pnpm lint:fix` |
| Type-check | `pnpm tsgo` |
| Run CLI (dev) | `pnpm openclaw ...` or `pnpm dev` |
| Gateway (dev) | `pnpm gateway:dev` |
| UI (dev) | `pnpm ui:dev` |

## Testing

| Task | Command |
|------|---------|
| All tests (parallel) | `pnpm test` |
| Unit tests only (fast) | `pnpm test:fast` |
| Watch mode | `pnpm test:watch` |
| Single test file | `pnpm test -- <pattern>` (e.g. `pnpm test -- auth-health`) |
| E2E tests | `pnpm test:e2e` |
| Live tests (real APIs) | `OPENCLAW_LIVE_TEST=1 pnpm test:live` |
| Coverage | `pnpm test:coverage` |

- Framework: Vitest with fork pool, 120s timeout, V8 coverage (70% thresholds)
- Tests are colocated: `src/foo.ts` → `src/foo.test.ts`, E2E in `*.e2e.test.ts`, live in `*.live.test.ts`
- Setup: `test/setup.ts` (fixtures, plugin stubs, isolated test homes)

## Architecture

### Monorepo Structure

- **`src/`** — Core TypeScript source (~1700 files)
- **`extensions/`** — ~37 channel plugin workspace packages (Matrix, Teams, Zalo, voice-call, etc.)
- **`ui/`** — Web UI (Vite + Lit with legacy decorators)
- **`packages/`** — Multi-agent variants (clawdbot, moltbot)
- **`apps/`** — Native apps (macOS/iOS via Swift, Android via Kotlin)
- **`docs/`** — Mintlify documentation site

### Key Source Directories

- `src/agents/` — AI agent integration, auth profiles, tools, sandbox execution
- `src/channels/` — Channel plugin interfaces, outbound routing and delivery
- `src/cli/` — Commander.js CLI program, command wiring
- `src/commands/` — One file per CLI command (auth, config, send, talk, etc.)
- `src/config/` — Zod-validated config loading, sessions
- `src/gateway/` — WebSocket server, control UI, protocol handlers
- `src/infra/` — Cross-cutting: errors, ports, binaries, env, paths
- `src/plugins/` — Plugin registry and runtime loading
- `src/media/` — Media understanding, parsing, compression
- `src/terminal/` — CLI UI helpers (tables, palette, progress)
- Channel implementations: `src/discord/`, `src/telegram/`, `src/slack/`, `src/signal/`, `src/imessage/`, `src/web/` (WhatsApp), `src/webchat/`, `src/browser/`

### Core Patterns

**Dependency Injection via `deps`**: Functions accept a `deps` parameter built from `createDefaultDeps()` (`src/cli/deps.ts`). Maps channel-specific send functions. Tests substitute stubs.

**Channel Plugin System**: All channels implement `ChannelPlugin` interface. Core channels are built-in; extension channels live in `extensions/` as workspace packages. Plugin registry at `src/plugins/registry.ts`. Runtime loads extensions via jiti, resolving `openclaw/plugin-sdk` as an alias.

**Config**: `OpenClawConfig` Zod schema (`src/config/zod-schema.ts`), stored at `~/.openclaw/config.json` (JSON5). Validation in `src/config/validation.ts`.

**Build Pipeline**: tsdown compiles `src/` → `dist/`. Entrypoints: `src/index.ts`, `src/entry.ts`, `src/plugin-sdk/index.ts`, `src/extensionAPI.ts`, plus bundled hooks.

## Code Conventions

- **TypeScript ESM only** — strict mode, no `any` (linter error), file extensions required in imports
- **Formatting/linting**: Oxfmt + Oxlint (Rust-based, fast). Run `pnpm check` before commits
- **Product naming**: "OpenClaw" in prose/headings; `openclaw` for CLI/package/paths/config keys
- **Max file size**: ~500 LOC guideline (`pnpm check:loc`); split when it improves clarity
- **CLI progress**: use `src/cli/progress.ts` (osc-progress + clack spinner), not hand-rolled
- **Status tables**: use `src/terminal/table.ts` for ANSI-safe wrapping
- **Colors**: use shared palette in `src/terminal/palette.ts`, no hardcoded colors
- **Tool schemas**: avoid `Type.Union`; use `stringEnum`/`Type.Optional` instead. Avoid raw `format` property name

## Git & Commits

- **Commit via**: `scripts/committer "<msg>" <file...>` (scoped staging, avoids manual git add/commit)
- **Messages**: concise, action-oriented (e.g. `CLI: add verbose flag to send`)
- **Pre-commit hooks**: `git config core.hooksPath git-hooks` (runs oxlint + oxfmt on staged files)
- **PR workflow**: see `.agents/skills/PR_WORKFLOW.md` and `docs/help/submitting-a-pr.md`

## Extension Development

Extensions live in `extensions/<name>/` as pnpm workspace packages:
- Export a `ChannelPlugin` interface implementation
- `package.json` must include `"openclaw": { "extensions": ["./index.ts"] }`
- Runtime deps in `dependencies` (plugin install runs `npm install --omit=dev`)
- Put `openclaw` in `devDependencies` or `peerDependencies`, never `workspace:*` in `dependencies`
- Plugin SDK import: `openclaw/plugin-sdk` (resolved via jiti alias at runtime)
- Test with `createTestRegistry()` from `src/test-utils/channel-plugins.ts`

## Important Constraints

- Node **22+** required. Keep both Node and Bun paths working
- Never update the Carbon or Readability dependencies
- Patched dependencies (`pnpm.patchedDependencies`) must use exact versions (no `^`/`~`)
- Patching deps requires explicit approval
- Version locations span multiple files — see AGENTS.md "Version locations" for the full list
- Do not rebuild the macOS app over SSH; must run directly on Mac
- Never send streaming/partial replies to external messaging channels; only final replies
