# OpenCode Setup

## Provider Auth

### OpenCode Go

1. Sign up at [opencode.ai/auth](https://opencode.ai/auth)
2. Subscribe to OpenCode Go ($5 first month, then $10/month)
3. Copy your API key
4. In the OpenCode TUI, run `/connect` and select "OpenCode Go"
5. Paste your API key

### MiniMax

1. Sign up at [MiniMax](https://www.minimaxi.com)
2. Get your API key
3. In the OpenCode TUI, run `/connect`, search for "Other"
4. Enter provider ID: `minimax`
5. Paste your API key

### DeepSeek

1. Sign up at [DeepSeek](https://platform.deepseek.com)
2. Get your API key
3. In the OpenCode TUI, run `/connect`, search for "Other"
4. Enter provider ID: `deepseek`
5. Paste your API key

Auth is stored in `~/.local/share/opencode/auth.json` (not in the nix store).

## Model Routing (oh-my-opencode-slim)

Configured in `oh-my-opencode-slim.json` via the `"smores"` preset.

| Agent | Model | Provider |
|-------|-------|----------|
| Orchestrator | `minimax/MiniMax-M2.7` | MiniMax |
| Oracle | `deepseek/deepseek-v4-pro` (high) | DeepSeek |
| Council | `deepseek/deepseek-v4-pro` | DeepSeek |
| Explorer | `minimax/MiniMax-M2.7` | MiniMax |
| Librarian | `minimax/MiniMax-M2.7` | MiniMax |
| Designer | `minimax/MiniMax-M2.7` | MiniMax |
| Fixer | `deepseek/deepseek-v4-flash` (high) | DeepSeek |
| Observer | `minimax/MiniMax-M2.7` | MiniMax |

Orchestrator, Designer, and Observer fall back to `deepseek/deepseek-v4-pro` if MiniMax is unavailable.

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

### Pi — `v2nic/pi-caveman`

Extension installed at `~/.pi/agent/extensions/caveman/index.ts` from a pinned upstream commit.

Commands: `/caveman` (toggle), `/caveman lite`, `/caveman full`, `/caveman ultra`.

Auto-triggers on: "caveman mode", "talk like caveman", "less tokens", "be brief".

## OpenChamber Web UI

Smortress is the sole host for OpenCode/OpenChamber services, accessible at `http://smortress:3000` over Tailscale.

Proxied at `https://opencode.sammohr.dev` via Caddy on smoresnet (see `openchamber-proxy/`).

## Herdr Hosted Bridge

On `smortress`, Home Manager installs Herdr, a local-only `ttyd` bridge, and scripts for Tailscale Serve.

```bash
herdr-hosted-serve
```

The hosted bridge uses one Herdr runtime namespace, `hosted`. When the web terminal opens, it prompts for a workspace target using a mouse-aware picker that shows `Home` or repo labels like `github.com/smores56/nix-config`. Choosing a target focuses an existing Herdr workspace for that folder or creates one.

You can skip the picker from a shell:

```bash
herdr-hosted
herdr-hosted nix-config
herdr-hosted ~/code/github.com/smores56/nix-config
```

The bridge serves Herdr through `ttyd` on `127.0.0.1:7681` and configures Tailscale Serve on HTTPS port 443. It requires Tailscale Serve's `Tailscale-User-Login` identity header, so direct requests to the local `ttyd` port are not accepted.

The browser terminal defaults to a larger mobile-friendly font size. Override it per visit with a query string, for example `https://smortress.<tailnet>.ts.net/?fontSize=24`, or set `dotfiles.herdrHost.webTerminalFontSize`.

Useful commands:

```bash
herdr-hosted          # pick Home or a ghq repo, then attach locally
herdr-hosted work     # focus/create a matching ghq repo workspace
herdr-hosted-status
herdr-hosted-logs
herdr-omp-tab        # start omp in a new tab of the current Herdr workspace
hot                  # short shell alias for herdr-omp-tab
```

Inside Herdr, these extra bindings are configured:

```text
prefix+shift+o       start omp in a new tab of the current workspace
ctrl+shift+up        previous workspace
ctrl+shift+down      next workspace
ctrl+up              previous agent
ctrl+down            next agent
```

## Config Reload

On Linux hosts with `opencodeHost.bindAddress` set, `home-manager switch` restarts the opencode systemd service to pick up config changes. OpenChamber restarts too because it is bound to the opencode service.

## Pi/omp Provider Config

The omp `models.yml` and `config.yml` with API keys are user-managed outside Nix (in `~/.pi/`). The Nix config only installs the agent and extensions — provider credentials stay local.

## Fish Abbreviations

- `o` — Run `opencode` locally
