# OpenCode Setup

## Provider Auth

### OpenCode Go

1. Sign up at [opencode.ai/auth](https://opencode.ai/auth)
2. Subscribe to OpenCode Go ($5 first month, then $10/month)
3. Copy your API key
4. In the OpenCode TUI, run `/connect` and select "OpenCode Go"
5. Paste your API key

### Wafer (GLM-5.1)

1. Get your API key from [wafer.ai/pass](https://www.wafer.ai/pass)
2. In the OpenCode TUI, run `/connect`, search for "Other"
3. Enter provider ID: `wafer`
4. Paste your API key

Auth is stored in `~/.local/share/opencode/auth.json` (not in the nix store).

## Model Routing (oh-my-opencode-slim)

Configured in `oh-my-opencode-slim.json` via the `"smores"` preset.

| Agent | Model | Budget |
|-------|-------|--------|
| Orchestrator | `wafer/GLM-5.1` | wafer (1,000 req/5hr) |
| Oracle | `wafer/GLM-5.1` (high) | wafer |
| Council | `opencode-go/deepseek-v4-pro` | go |
| Explorer | `opencode-go/minimax-m2.7` | go |
| Librarian | `opencode-go/minimax-m2.7` | go |
| Designer | `opencode-go/kimi-k2.6` | go |
| Fixer | `opencode-go/deepseek-v4-flash` (high) | go |
| Observer | `opencode-go/kimi-k2.6` | go |

Orchestrator and Oracle fall back to `opencode-go/deepseek-v4-pro` if wafer.ai is down or rate-limited.

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

## OpenChamber Web UI

Personal hosting is accessible at `http://smortress:3000` over Tailscale. The web UI and TUI connect to the same backend server, so sessions are shared.

Proxied at `https://opencode.sammohr.dev` via Caddy on smoresnet (see `openchamber-proxy/`).

The work host runs a local-only pair:

- OpenChamber: `http://openchamber.local:15500`
- OpenCode backend: `http://openchamber.local:16500`

Map `openchamber.local` to `127.0.0.1` in `/etc/hosts` or local DNS if needed. On macOS:

```bash
grep -q '^127\.0\.0\.1[[:space:]]\+openchamber\.local$' /etc/hosts || \
  echo '127.0.0.1 openchamber.local' | sudo tee -a /etc/hosts
```

## Herdr Phone Bridge

On `smortress`, Home Manager installs Herdr, a local-only `ttyd` bridge, and scripts for Tailscale Serve.

```bash
herdr-phone-serve
```

The phone bridge uses one Herdr runtime namespace, `phone`. When the web terminal opens, it prompts for a workspace target: `Home` or any repo from `ghq list -p`. Choosing a target focuses an existing Herdr workspace for that folder or creates one.

You can skip the picker from a shell:

```bash
herdr-phone
herdr-phone nix-config
herdr-phone ~/code/github.com/smores56/nix-config
```

The bridge serves Herdr through `ttyd` on `127.0.0.1:7681` and configures Tailscale Serve on HTTPS port 443. It requires Tailscale Serve's `Tailscale-User-Login` identity header, so direct requests to the local `ttyd` port are not accepted.

Useful commands:

```bash
herdr-phone          # pick Home or a ghq repo, then attach locally
herdr-phone work     # focus/create a matching ghq repo workspace
herdr-phone-status
herdr-phone-logs
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

On Linux hosts with hosting enabled, `home-manager switch` restarts the opencode systemd service to pick up config changes. OpenChamber restarts too because it is bound to the opencode service. On macOS work hosts, Home Manager manages the launchd agents.

## Fish Abbreviations

- `o` — Attach to the configured hosted OpenCode instance. Personal configs default to `http://smortress:4000`; the work config uses `http://openchamber.local:16500`.
