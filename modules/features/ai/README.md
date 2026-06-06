# AI Tools Setup

## API Keys

API keys are loaded from environment variables defined in `~/.config/fish/conf.d/api-keys.fish`:

```fish
set -gx XIAOMI_MIMO_API_KEY "sk-..."
set -gx DEEPSEEK_API_KEY "sk-..."
```

These are sourced by fish automatically and available to all AI tools.

## Model Hierarchy

### Personal Machines (all except smoreswork)

| Tier | Provider / Model | Role |
|------|-----------------|------|
| Smartest | `xiaomi/mimo-v2.5-pro` | Default, plan, slow, task — highest reasoning effort |
| Middle | `xiaomi/mimo-v2.5` | Smol, commit, vision, designer |
| Cheap / Local | `smortress/gemma-4-31b` | Free, self-hosted on smortress via llama.cpp |
| Backup | DeepSeek (via API) | Available but not used by default |

No minimax, CrofAI, or other providers are configured.

### Work Machine (smoreswork)

| Tier | Provider / Model | Role |
|------|-----------------|------|
| Primary | `openai-codex/gpt-5.5-codex` | All model roles |
| Backup | `anthropic/claude-opus-4-8` | Available but not used by default |

No other models are available on the work machine.

## Provider Setup

### Xiaomi MiMo

1. Get API key from Xiaomi Token Plan
2. Add to `~/.config/fish/conf.d/api-keys.fish`: `set -gx XIAOMI_MIMO_API_KEY "sk-..."`
3. OpenCode: run `/connect`, search for "Other", enter provider ID `xiaomi`, paste key
4. oh-my-pi: key is read from `XIAOMI_MIMO_API_KEY` env var at activation time

### DeepSeek (Backup)

1. Get API key from [DeepSeek](https://platform.deepseek.com)
2. Add to `~/.config/fish/conf.d/api-keys.fish`: `set -gx DEEPSEEK_API_KEY "sk-..."`
3. Available in `modelProviderOrder` but not assigned to any default role

## Model Routing

OpenCode and oh-my-pi use these role assignments:

### Personal

| Role | Model | Why |
|------|-------|-----|
| Default / orchestrator / plan | `xiaomi/mimo-v2.5-pro` | Best reasoning, 1M context, high effort |
| Slow / oracle | `xiaomi/mimo-v2.5-pro` | Same as default for complex debugging |
| Task | `xiaomi/mimo-v2.5-pro` | Bounded implementation work |
| Smol / commit | `smortress/gemma-4-31b` | Free local model for routine work |
| Vision / designer | `xiaomi/mimo-v2.5` | Mid-tier for visual/design tasks |

### Work

| Role | Model |
|------|-------|
| All roles | `openai-codex/gpt-5.5-codex` |

## OpenCode

OpenCode uses `oh-my-opencode-slim` instead of `oh-my-openagent` to reduce automatic subagent/council traffic.

### Primary Agents

OpenCode exposes primary agents for direct model switching:

| Agent | Model |
|-------|-------|
| Codex | `openai/gpt-5.5-codex` |
| Claude | `anthropic/claude-opus-4-8` |

### OCX Workspace Profile

Auto-installed on first `home-manager switch`. If it fails, run manually:

```bash
ocx init --global
ocx profile add ws --source tweak/p-1vp4xoqv --from https://tweakoc.com/r --global
```

## Caveman Plugins

### OpenCode — `caveman-opencode-plugin`

Installed via `opencode plugin` and configured in `~/.config/opencode/caveman.json`.

Commands: `/caveman <mode>`, `/caveman-commit <diff>`, `/caveman-review <code>`.

Modes: `lite`, `full` (default), `ultra`, `wenyan-lite`, `wenyan-full`, `wenyan-ultra`, `off`.

### oh-my-pi — `v2nic/pi-caveman`

Installed via `oh-my-pi.nix` activation when `dotfiles.ohMyPi.enable = true`.

Commands: `/caveman` (toggle), `/caveman lite`, `/caveman full`, `/caveman ultra`.

## OpenChamber Web UI

Smortress is the sole host for OpenCode/OpenChamber services, accessible at `http://smortress:3000` over Tailscale.

Exposed publicly at `https://opencode.sammohr.dev` via Cloudflare Tunnel (see the repo README, "Public Web Exposure").

## Config Reload

On Linux hosts with `opencodeHost.bindAddress` set, `home-manager switch` restarts the opencode systemd service to pick up config changes. OpenChamber restarts too because it is bound to the opencode service.

## oh-my-pi Config

Managed by `oh-my-pi.nix` (set `dotfiles.ohMyPi.enable = true`). On `home-manager switch`:

- Installs the oh-my-pi CLI package under `~/.local/share/oh-my-pi-cli` if it is missing
- Installs `pi-caveman` via `omp plugin install`
- Generates `~/.omp/agent/models.yml` and `~/.omp/agent/config.yml` from env vars and Nix config
- Sets `steeringMode: one-at-a-time`

### oh-my-pi Model Config

On personal machines, home-manager generates:
- `~/.omp/agent/models.yml` — Xiaomi provider with MiMo V2.5 Pro and MiMo V2.5, plus smortress with Gemma 4 31B
- `~/.omp/agent/config.yml` — model roles mapped to the Xiaomi/smortress distribution above

On work machines (`dotfiles.workModels = true`):
- `~/.omp/agent/models.yml` — minimal, OAuth-discovered providers
- `~/.omp/agent/config.yml` — all roles mapped to GPT 5.5 Codex, Claude Opus 4.8 available

Compaction settings:
- `keepRecentTokens = 48000`
- `reserveTokens = 32768`

To expose Codex OAuth credentials to OMP:

```nix
dotfiles.ohMyPi.codex.enable = true;
```

The wrapper exports the current Codex access token from `~/.codex/auth.json`.

To also expose Claude Code OAuth credentials to OMP:

```nix
dotfiles.ohMyPi.claude.enable = true;
```

The wrapper exports the current Claude Code access token from `~/.claude/.credentials.json`, and activation imports the
Claude OAuth credential into OMP's local auth store when no Anthropic credential exists yet.

### Plugin Selection Rationale

omp (~27K LoC Rust) has extensive built-in token reduction. Many popular plugins duplicate built-in features:

| Plugin | Overlap | Verdict |
|--------|---------|---------|
| context-mode | HIGH — built-in compaction, search, eval, tool hooks | SKIP |
| pi-lean-ctx | MOD-HIGH — read summarization, session memory, LSP built-in | SKIP (+ heavy `brew install` dep) |
| pi-loadout | HIGH — `--tools` already pins tools | SKIP |
| pi-context-tools | MOD — agent-callable compaction adds convenience over `/compact` | SKIP (marginal) |
| pi-context-prune | HIGH — auto-compaction + tool-output pruning built-in | SKIP |
| pi-context-usage | MINIMAL — pure visualization, but current release expects an OMP export missing in v15.5.10 | SKIP |

### Fish Abbreviations

- `oc` — Run `omp --tools read,edit,write,search,find,bash,lsp,todo_write,ask` for minimal-context sessions
- `o` — Run `opencode` locally
