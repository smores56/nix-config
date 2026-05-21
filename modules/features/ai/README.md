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

## OCX Workspace Profile

Auto-installed on first `home-manager switch`. If it fails, run manually:

```bash
ocx init --global
ocx profile add ws --source tweak/p-1vp4xoqv --from https://tweakoc.com/r --global
```

## OpenChamber Web UI

Accessible at `http://campfire:3000` over Tailscale. The web UI and TUI connect to the same backend server, so sessions are shared.

Proxied at `https://opencode.sammohr.dev` via Caddy on smoresnet (see `portal-proxy/`).

## Config Reload

On hosts with `opencodeServe = true`, `home-manager switch` automatically restarts the opencode systemd service to pick up config changes. OpenChamber restarts too (it's bound to the opencode service).

## Fish Abbreviations

- `o` — Attach to the campfire-hosted OpenCode instance (`opencode attach http://campfire:4000`)
