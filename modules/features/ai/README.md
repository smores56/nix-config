# AI Tools Setup

Pi is the primary coding agent on every machine (see `pi/EXTENSIONS.md` for
the full extension stack and decision record). oh-my-pi (omp) is kept as a
minimal backup agent for when pi breaks - agent config only, no plugins.

## API Keys

API keys are loaded from environment variables defined in
`~/.config/fish/conf.d/api-keys.fish`:

```fish
set -gx XIAOMI_MIMO_API_KEY "sk-..."
set -gx DEEPSEEK_API_KEY "sk-..."
```

These are sourced by fish automatically and available to all AI tools.

## Model Hierarchy

### Personal Machines

| Tier | Provider / Model | Role |
|------|-----------------|------|
| Strong | `xiaomi/mimo-v2.5-pro` | Default + strong-tier subagents |
| Weak | `xiaomi/mimo-v2.5` | Weak-tier subagents, naming, summaries |
| Fallbacks | DeepSeek v4 -> CrofAI Kimi K2.7 -> `smortress/gemma-4-31b` | Failover chain on both tiers |

`smortress/gemma-4-31b` is free and self-hosted via llama.cpp
(`modules/nixos/llm.nix`, enabled by the `llm` host flag).

### Work Machine (smoreswork)

| Tier | Provider / Model |
|------|-----------------|
| Strong | `anthropic/claude-opus-4-8` |
| Weak | `anthropic/claude-sonnet-4-6` |

`anthropic/claude-fable-5` stays selectable via `/model`; it is no longer the default.

## Provider Modules

- `xiaomi.nix`, `deepseek.nix`, `crofai.nix` - shared provider/model
  definitions consumed by pi and omp via `_module.args`
- `llm-token-bucket-proxy/` - user service on smortress meant to meter all
  Xiaomi MiMo traffic against the monthly token bucket.
  **Follow-up:** xiaomi.nix currently points straight at the MiMo API, so
  the proxy is not yet in the request path. Either route the provider
  baseUrl through it or replace it with an off-the-shelf budget proxy
  (e.g. LiteLLM budgets) and delete this module.

## Sandboxing (nono)

Managed by `nono.nix` (the `dotfiles.nono.*` options; nono is always
installed, every host — the option was made unconditional when no host ever
disabled it). Every agent runs inside a kernel-enforced sandbox via
[nono](https://github.com/always-further/nono) (`pkgs.nono`) - one tool, both
OSes: **Landlock** on Linux, **Seatbelt** on macOS. The launchers all go
through a shared `nono-agent` wrapper (a `writeShellScriptBin` in `nono.nix`)
that runs `nono run -s --allow-cwd --allow-connect-port 22/443 -p <profile>
-- <agent>`. Call sites: the `m`/`o`/`pi` fish abbrs (`nono-agent maki`,
etc.), the paseo `maki` ACP provider command, herdr's maki pane
(`nono-agent maki`), and `start_worktree_session.lua`.

Profiles live at `~/.config/nono/profiles/` (generated JSON):

- `agent-base` extends nono's built-in `default` (which already denies `~/.ssh`,
  cloud creds, shell configs/history, keychains). On top it grants the language
  toolchains read-only (`nix_runtime` covers almost everything on NixOS, plus
  node/rust/python/go/git/user_tools), a read-write workdir + `~/.bun` read (for
  bun-installed agents), and denies `~/.config/gh`.
- `maki`/`pi`/`omp` extend `agent-base` and add only their own state dirs (rw).

Enforced kernel-level and inherited by every child (so maki's `bash` tool can't
escape it either):

- **Read-only** toolchains/config; **read-write** only the workdir + each agent's
  state. SSH keys, cloud creds, and the rest of `$HOME` are invisible.
- **No sudo** - `/run/wrappers` (the setuid sudo) is never granted, so no child
  can exec it, with or without `NoNewPrivileges`.
- **Denying `~/.config/gh`** also hides maki's Copilot provider: maki probes
  `gh/hosts.yml` for a token and 403s on every launch otherwise; with the read
  blocked it skips Copilot. `gh` itself runs outside the sandbox, unaffected.

Network egress is default-deny via `restrictNetwork` (default on): `agent-base`
sets nono's built-in `developer` profile (`llm_apis`, `package_registries`,
`github`, `sigstore`, `documentation`) plus an `allow_domain` list for the
endpoints no group covers - mimo (personal default LLM), crofai, the byterover
MCP (`*.byterover.dev`), and the smortress host. Two consequences: agents get
**no general web/search** (only the curated `documentation` hosts), and nono's
proxy is HTTPS-CONNECT-only so the local plain-HTTP gemma backend is
unreachable - set `dotfiles.nono.restrictNetwork = false` for unrestricted
egress. Verified end-to-end on smortress (Landlock) and macOS (Seatbelt):
maki/pi/omp run, allowed LLMs reach (mimo/deepseek/crofai), unlisted hosts get
a 403 CONNECT block, and `~/.ssh`, `~/.config/gh`, `sudo` stay blocked.

## oh-my-pi (Backup Agent)

Managed by `oh-my-pi/default.nix` (`dotfiles.ohMyPi.enable`, default on).
On `home-manager switch`:

- Installs the omp CLI under `~/.local/share/oh-my-pi-cli` if missing
- Generates `~/.omp/agent/models.yml` and `~/.omp/agent/config.yml` from
  the shared provider modules
- Imports Codex/Claude OAuth credentials when `ohMyPi.codex.enable` /
  `ohMyPi.claude.enable` are set (work machine)
- Uninstalls previously-installed plugins (minimal backup = no plugins)

Fish shortcut: `o` = `omp` (wrapped in its nono sandbox; see Sandboxing above).

## maki (config-only)

Managed by `maki/default.nix` (`dotfiles.maki.enable`, default on). The maki
binary is installed manually (`maki.sh/install.sh`); home-manager only writes
`~/.config/maki/`:

- `init.lua` - `maki.setup` with `always_yolo`, `always_thinking`, and a
  `provider.default_model` mirroring pi/omp: `anthropic/claude-opus-4-8` on the
  work machine, `deepseek/deepseek-v4-pro` elsewhere. `bash` tool enabled.
  `anthropic/claude-fable-5` stays in maki's built-in strong tier (`/model`).
- `plugin.toml` - grants config Lua plugins `run`/`env` (absent manifest =
  every plugin capability denied).
- `lua/spawn_session.lua` - custom Lua tool that spawns a new maki session as a
  detached Paseo agent (`paseo run --provider maki`) behind a confirmation
  dialog, attachable from the CLI or app.paseo.sh. Self-disables without `paseo`.
- `mcp.toml` (only when `maki.byteroverMemory`, on for smortress) - registers
  byterover (`brv mcp`) as an MCP server and disables maki's built-in `memory`
  tool, so memory runs through byterover's `byterover__*` tools. `brv` must be
  installed and on maki's PATH (manual; smortress only).
- `maki-codex-sync` (work machine) - mirrors standard Codex CLI ChatGPT OAuth
  credentials from `~/.codex/auth.json` into Maki's
  `~/.local/state/maki/auth/openai.json`. Run `codex login`, then
  `maki-codex-sync` before starting Maki.
- `providers/{xiaomi,crofai,smortress}` - executable dynamic-provider scripts
  (personal hosts only) registering the custom OpenAI-compatible endpoints maki
  has no built-in for: Xiaomi MiMo, CrofAI (Kimi K2.7 Code), and the self-hosted
  `smortress/gemma-4-31b`. Each answers `info`/`models`/`resolve`; `resolve`
  injects the bearer token from the env key (`XIAOMI_MIMO_API_KEY` /
  `CROFAI_API_KEY`; gemma is keyless), and `info`'s `has_auth` gates the provider
  on the key being present. base `llama-cpp` is the plain OpenAI-compatible
  dialect; maki auto-discovers each endpoint's live `/v1/models` list.

Editor/remote use is over ACP (`maki acp`). See Paseo and Herdr below for the
two ways to reach a live maki session from another device.

## Paseo (orchestrator + remote UI)

Managed by `paseo.nix` (`dotfiles.paseo.enable`, off by default; on for the
smortress server). The `paseo` binary is installed manually (bun/npm global);
home-manager writes `~/.paseo/config.json` and runs the daemon as a systemd user
service whose PATH unions the manual-install bin dirs (bun/npm/nix-profile/cargo/
brv-cli) so it finds `paseo`, the `maki acp` it spawns, and `brv`. The unit runs
`paseo daemon start --foreground` so Type=simple supervises it. It registers maki
as an ACP provider
(`agents.providers.maki = maki acp`), binds the daemon to `127.0.0.1:6767`, and
web-proxy.nix tunnels it to `paseo.sammohr.dev`.

- Paseo renders its OWN UI (web/mobile/CLI) over a headless `maki acp`; you do
  not see maki's native TUI through it. Use it for orchestration and a phone UI,
  and to share one live session across CLI (`paseo attach`) and app.paseo.sh
  without teardown/resume (the daemon is the single ACP client to maki).
- Auth: the daemon is unauthenticated by default. `dotfiles.paseo.environmentFile`
  is a required (fail-closed) systemd EnvironmentFile holding `PASEO_PASSWORD`
  plus the provider key the spawned maki needs (`DEEPSEEK_API_KEY`, or
  `ANTHROPIC_API_KEY` for opus). Cloudflare gives edge TLS; put Cloudflare
  Access in front of `paseo.sammohr.dev` for a stronger gate on a code-executing
  daemon. The relay (QR pairing, E2E) needs no tunnel and is the simplest mobile
  path.

## Herdr (maki's real TUI, multiplexed)

Managed by `herdr/default.nix` (`dotfiles.herdr.enable`, default on). The herdr
binary is installed manually; home-manager writes `~/.config/herdr/config.toml`
(gruvbox, fish panes, `prefix+alt+m` -> maki pane) and installs herdr's agent
`SKILL.md` into `~/.config/maki/skills/herdr/` so maki can drive herdr from
inside a pane. Herdr runs the ACTUAL maki TUI in a persistent pane, reachable
from any terminal (ssh/Tailscale or a browser terminal) with detach/reattach and
live handoff. Herdr's binary has no maki detector, so maki panes show as plain
terminals unless maki reports state over the socket API.

## Web Access (smortress)

- `pi.sammohr.dev` - pi-agent-dashboard (`dotfiles.piDashboard`), the
  phone-accessible web UI for pi sessions
- `paseo.sammohr.dev` - Paseo daemon (`dotfiles.paseo`), web/mobile UI driving a
  headless `maki acp`; see Paseo above
- Local TUI access from any device: ssh (Tailscale) + `pi-hub` (tmux-backed
  session dashboard, see `pi/EXTENSIONS.md`)
- For the actual maki TUI on the web: run maki inside Herdr (or tmux) and reach
  it over ssh or a browser terminal behind the web proxy (see Herdr above)

## Claude Code

`default.nix` writes shared agent guidelines (`dotfiles.aiHints`) to
`~/.claude/CLAUDE.md`. Claude Code is used occasionally; this is its only
footprint.

## History

OpenCode (+ OpenChamber/OCX), goose (+ web PWA), pinano,
Agent of Empires, and the Hermes Agent deployment (Docker sandbox +
Discord gateway) were removed in June 2026 after consolidating on pi.
`git log -- modules/features/ai` has the receipts if anything needs
resurrecting.
