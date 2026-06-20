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
| Fallbacks | DeepSeek v4 -> `smortress/gemma-4-31b` | Failover chain on both tiers |

`smortress/gemma-4-31b` is free and self-hosted via llama.cpp
(`modules/nixos/llm.nix`, enabled by the `llm` host flag).

### Work Machine (smoreswork)

| Tier | Provider / Model |
|------|-----------------|
| Strong | `anthropic/claude-opus-4-8` |
| Weak | `anthropic/claude-sonnet-4-6` |

`anthropic/claude-fable-5` stays selectable via `/model`; it is no longer the default.

## Provider Modules

- `xiaomi.nix`, `deepseek.nix` - shared provider/model
  definitions consumed by pi and omp via `_module.args`
- `llm-token-bucket-proxy/` - user service on smortress meant to meter all
  Xiaomi MiMo traffic against the monthly token bucket.
  **Follow-up:** xiaomi.nix currently points straight at the MiMo API, so
  the proxy is not yet in the request path. Either route the provider
  baseUrl through it or replace it with an off-the-shelf budget proxy
  (e.g. LiteLLM budgets) and delete this module.

## Sandboxing (nono)

Managed by `nono.nix` (`dotfiles.nono.*`; on by default, every host). Every
agent runs inside a kernel-enforced sandbox via
[nono](https://github.com/always-further/nono) (`pkgs.nono`) - one tool, both
OSes: **Landlock** on Linux, **Seatbelt** on macOS. The launchers all go
through a shared `nono-agent` wrapper (a `writeShellScriptBin` in `nono.nix`)
that runs `nono run -s --allow-cwd -p agent -- <cmd>`. Call sites: the
`m`/`o`/`pi` fish abbrs (`nono-agent maki`, etc.), herdr's maki pane
(`nono-agent maki`), and `start_worktree_session.lua` (which prepends `exec`
so nono becomes the detached worktree's session leader for signal/job-control
— the only `exec` site; abbrs and the herdr pane spawn nono-agent as a reaped
child, not a shell replacement).

There is a **single shared `agent` profile** at `~/.config/nono/profiles/agent.json`
(generated JSON) shared by maki/pi/omp — the per-agent profile split was dropped
once the network block went away (the only remaining differences were which
agent-state dirs and which API-key env vars to expose, both thin enough to
union into one profile).

**Isolation model: open network, filtered env + filesystem.** Network is
left unrestricted (nono `AllowAll`) — no `--network-profile`, no
`--allow-domain`, no credential routes, no `--allow-connect-port`. Raw-TCP
SSH on `:22` works again on both Linux and macOS (the old `--allow-connect-port`
flag was Linux-only and a hard error at apply time on macOS Seatbelt, which
broke the work host until now). mitmproxy and its L7 method filtering were
deleted as dead weight once nono's egress gate was dropped.

The secret-control surface is:

- **Env-var allow-list** (`environment.allow_vars`): a curated set — `PATH`,
  `HOME`, `TERM`, `LANG`, `LC_ALL`, `USER`, `SHELL`, `XDG_*`, `TMPDIR`,
  `SSH_AUTH_SOCK`, plus the LLM/MCP API keys the agents actually read
  (`NEURALWATT_API_KEY`/`XIAOMI_MIMO_API_KEY`/
  `DEEPSEEK_API_KEY`/`CLOUDFLARE_*`/`GLEAN_*`/`SLACK_MCP_*`). Everything else
  is stripped before the sandbox is applied; nono's non-overridable built-in
  blocklist also blocks `LD_PRELOAD`, `DYLD_*`, `PYTHONPATH`, `NODE_OPTIONS`
  regardless. With network open, any secret in the shell env would be both
  readable and exfiltrable, so the allow-list is the primary secret control.
  Agents do **not** read `GH_TOKEN`/`GITHUB_TOKEN` (git auth is ssh-agent
  signing + `gh` running outside the sandbox), so those stay stripped.
- **Filesystem denies** layered on top of nono's built-in `default` (which
  already denies `~/.ssh`/`~/.aws`/`~/.gnupg`/`~/.kube`/`~/.docker`,
  keychains, browser data, shell history/configs): denies
  `~/.config/fish/conf.d` (the `api-keys.fish` file, defense in depth on top
  of `deny_shell_configs`) and `~/.config/gh` (gh OAuth token — also silences
  maki's Copilot provider probe, which 403s on every launch otherwise; `gh`
  itself runs outside the sandbox, unaffected).
- **No sudo** — `/run/wrappers` is never granted, so no child can exec the
  setuid sudo.
- **Read-only** toolchains/config; **read-write** only the workdir + each
  agent's own state dirs.

`~/code` (incl. this nix-config repo and its `~/.config/home-manager`
symlink target) is **writable from inside the sandbox**. This is safe because
a running nono session's capability set is kernel-fixed at startup and
**irreversible** — there is no live-reload, file-watch, or in-process config
refresh that could widen it. Editing `~/.config/nono/profiles/agent.json`
from inside the sandbox has zero effect on the running session (it only
influences the *next* `nono run`), and that profile JSON is a `home.file`
symlink into the read-only Nix store, so a sandboxed process can't even
overwrite it (at most it replaces the symlink, which only changes the next
run). Supervisor-mode widening exists but requires operator `/dev/tty`
approval via the seccomp notify fd, never a silent config write.

**Dangerous-mode escape hatch by design:** occasionally an agent needs to edit
sensitive personal config that's explicitly denied. There's *no* abbr for that
— type `exec maki` / `exec pi` / `exec omp` directly (no wrapper) when you
need it. The safe path is shorter to type, on purpose (pit of success).

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
- `mcp.toml` (only when `maki.byteroverMemory`, on for smortress) - registers
  byterover (`brv mcp`) as an MCP server and disables maki's built-in `memory`
  tool, so memory runs through byterover's `byterover__*` tools. `brv` must be
  installed and on maki's PATH (manual; smortress only).
- `maki-codex-sync` (work machine) - mirrors standard Codex CLI ChatGPT OAuth
  credentials from `~/.codex/auth.json` into Maki's
  `~/.local/state/maki/auth/openai.json`. Run `codex login`, then
  `maki-codex-sync` before starting Maki.
- `providers/{xiaomi,smortress}` - executable dynamic-provider scripts
  (personal hosts only) registering the custom OpenAI-compatible endpoints maki
  has no built-in for: Xiaomi MiMo, and the self-hosted
  `smortress/gemma-4-31b`. Each answers `info`/`models`/`resolve`; `resolve`
  injects the bearer token from the env key (`XIAOMI_MIMO_API_KEY`;
  gemma is keyless), and `info`'s `has_auth` gates the provider
  on the key being present. base `llama-cpp` is the plain OpenAI-compatible
  dialect; maki auto-discovers each endpoint's live `/v1/models` list.

Editor/remote use is over ACP (`maki acp`). See Herdr below for the other way
to reach a live maki session from another device.

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
