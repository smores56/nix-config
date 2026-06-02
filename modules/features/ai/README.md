# OpenCode Setup

## Provider Auth

### OpenCode Go

1. Sign up at [opencode.ai/auth](https://opencode.ai/auth)
2. Subscribe to OpenCode Go ($5 first month, then $10/month)
3. Copy your API key
4. In the OpenCode TUI, run `/connect` and select "OpenCode Go"
5. Paste your API key

### CrofAI

1. Sign up at [CrofAI](https://crof.ai) and subscribe to Scale or higher.
2. OpenCode: run `/connect`, search for "Other", enter provider ID `crofai`, then paste the CrofAI key.
3. oh-my-pi: write the key to `~/.config/omp/crofai-key` with mode `0600`.

Auth is stored outside the nix store:
- OpenCode: `~/.local/share/opencode/auth.json`
- oh-my-pi: `~/.config/omp/crofai-key`

### CrofAI Key Setup

OpenCode stores the key through `/connect`; do not put it in Nix:

```text
/connect → Other → provider ID: crofai → paste key
```

oh-my-pi reads the key from a local file that Home Manager never copies into the Nix store:

```bash
install -m 700 -d ~/.config/omp
printf '%s' 'sk-...' > ~/.config/omp/crofai-key
chmod 600 ~/.config/omp/crofai-key
```

Run `home-manager switch --no-update-lock-file` after creating the file. Without it, activation logs
`No CrofAI API key at ~/.config/omp/crofai-key` and leaves the previous OMP model config untouched.

## Model Routing

OpenCode and oh-my-pi route to CrofAI with request-minimized defaults:

| Role | Model | Why |
|------|-------|-----|
| Default / orchestrator / plan | `crofai/glm-5.1` | Strong planning/instruction following, Q6_K, 1 request |
| Slow / oracle / hard debug | `crofai/deepseek-v4-pro` | Best CrofAI coding model, Q6_K, 1M context, 1 request |
| Task / bounded implementation | `crofai/deepseek-v4-flash` | Good coding fallback, Q6_K, 0.75 request |
| Smol / explorer / librarian / commit | `crofai/glm-4.7-flash` | Cheap routine work, fp8, 0.5 request |
| Vision / designer | `crofai/kimi-k2.6` | Vision support, 1 request; avoid unless image/UI judgment matters |

Avoid precision/lightning models by default. The UI marks `*-precision` as 3 requests and `*-lightning` as 10 requests; the quality gain is not worth the request burn on Scale.

OpenCode uses `oh-my-opencode-slim` instead of `oh-my-openagent` to reduce automatic subagent/council traffic. `@tarquinen/opencode-smart-title` is intentionally not installed because title generation costs extra model requests.

## Primary Agents

OpenCode also exposes primary agents for direct model switching:

| Agent | Model |
|-------|-------|
| Codex | `openai/gpt-5.3-codex` |
| Claude | `anthropic/claude-sonnet-4-5` |

## OCX Workspace Profile

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
- Generates `~/.omp/agent/models.yml` and `~/.omp/agent/config.yml` from `~/.config/omp/crofai-key`
- Applies large-context compaction settings, because CrofAI is request-capped rather than token-capped
- Sets `steeringMode: one-at-a-time`

### oh-my-pi Model Config

Create the key file after subscribing:

```bash
install -m 700 -d ~/.config/omp
printf '%s' 'sk-...' > ~/.config/omp/crofai-key
chmod 600 ~/.config/omp/crofai-key
```

When present, home-manager generates:
- `~/.omp/agent/models.yml` — CrofAI provider with GLM 5.1, DeepSeek V4 Pro/Flash, GLM 4.7 Flash, and Kimi K2.6
- `~/.omp/agent/config.yml` — model roles mapped to the request-minimized CrofAI distribution above

Compaction settings are tuned to spend tokens instead of requests:
- `keepRecentTokens = 48000`
- `reserveTokens = 32768`
- large OpenCode tool output windows

To expose Codex OAuth credentials to OMP without making Codex the default:

```nix
dotfiles.ohMyPi.codex.enable = true;
```

The wrapper exports the current Codex access token from `~/.codex/auth.json`. CrofAI remains first in `modelProviderOrder`
and all model roles remain mapped to CrofAI.

To also expose Claude Code OAuth credentials to OMP:

```nix
dotfiles.ohMyPi.claude.enable = true;
```

The wrapper exports the current Claude Code access token from `~/.claude/.credentials.json`, and activation imports the
Claude OAuth credential into OMP's local auth store when no Anthropic credential exists yet. CrofAI remains the default.

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
