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
| Fallbacks | DeepSeek v4 -> CrofAI GLM -> `smortress/gemma-4-31b` | Failover chain on both tiers |

`smortress/gemma-4-31b` is free and self-hosted via llama.cpp
(`modules/nixos/llm.nix`, enabled by the `llm` host flag).

### Work Machine (smoreswork)

| Tier | Provider / Model |
|------|-----------------|
| Strong | `anthropic/claude-fable-5` |
| Weak | `anthropic/claude-sonnet-4-6` |

## Provider Modules

- `xiaomi.nix`, `deepseek.nix`, `crofai.nix` - shared provider/model
  definitions consumed by pi and omp via `_module.args`
- `llm-token-bucket-proxy/` - user service on smortress meant to meter all
  Xiaomi MiMo traffic against the monthly token bucket.
  **Follow-up:** xiaomi.nix currently points straight at the MiMo API, so
  the proxy is not yet in the request path. Either route the provider
  baseUrl through it or replace it with an off-the-shelf budget proxy
  (e.g. LiteLLM budgets) and delete this module.

## oh-my-pi (Backup Agent)

Managed by `oh-my-pi/default.nix` (`dotfiles.ohMyPi.enable`, default on).
On `home-manager switch`:

- Installs the omp CLI under `~/.local/share/oh-my-pi-cli` if missing
- Generates `~/.omp/agent/models.yml` and `~/.omp/agent/config.yml` from
  the shared provider modules
- Imports Codex/Claude OAuth credentials when `ohMyPi.codex.enable` /
  `ohMyPi.claude.enable` are set (work machine)
- Uninstalls previously-installed plugins (minimal backup = no plugins)

Fish shortcuts: `o` = `omp`, `oc` = omp with a pinned minimal toolset.

## Web Access (smortress)

- `pi.sammohr.dev` - pi-agent-dashboard (`dotfiles.piDashboard`), the
  phone-accessible web UI for pi sessions
- Local TUI access from any device: ssh (Tailscale) + `pi-hub` (tmux-backed
  session dashboard, see `pi/EXTENSIONS.md`)
- If a browser terminal is ever needed again: ttyd + `tmux attach` behind
  the web proxy was the agreed fallback (herdr was removed in favor of this)

## Claude Code

`default.nix` writes shared agent guidelines (`dotfiles.aiHints`) to
`~/.claude/CLAUDE.md`. Claude Code is used occasionally; this is its only
footprint.

## History

OpenCode (+ OpenChamber/OCX), goose (+ web PWA), maki, pinano, paseo,
herdr, Agent of Empires, and the Hermes Agent deployment (Docker sandbox +
Discord gateway) were removed in June 2026 after consolidating on pi.
`git log -- modules/features/ai` has the receipts if anything needs
resurrecting.
