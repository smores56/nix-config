# OpenCode Setup

## OpenCode Go Subscription

1. Sign up at [opencode.ai/auth](https://opencode.ai/auth)
2. Subscribe to OpenCode Go ($5 first month, then $10/month)
3. Copy your API key
4. In the OpenCode TUI, run `/connect` and select "OpenCode Go"
5. Paste your API key

Your auth is stored in `~/.local/share/opencode/auth.json` (not in the nix store).

## Wafer API Key (GLM-5.1)

For the heaviest/most difficult tasks, configure the Wafer provider:

1. Get your API key from [wafer.ai/pass](https://pass.wafer.ai/)
2. In the OpenCode TUI, run `/connect` and select "Other"
3. Enter provider ID: `wafer`
4. Paste your API key

Or set the environment variable:
```bash
export WAFER_API_KEY=wfr_...
```

To use GLM-5.1 for a session, run `/model wafer/GLM-5.1` in the TUI.

## OCX Workspace Profile

The OCX workspace profile is auto-installed on first `home-manager switch`. If auto-install fails, run manually:

```bash
ocx init --global
ocx profile add ws --source tweak/p-1vp4xoqv --from https://tweakoc.com/r --global
```

The workspace profile adds multi-agent orchestration (planner, coder, reviewer, scribe agents) and MCP servers. Use with `ocx oc -p ws` when launching OpenCode directly.

## Portal Web UI

Portal provides a web-based interface to OpenCode, accessible at:

```
http://smortress:3000
```

Access over Tailscale from any device. The web UI and TUI connect to the same backend server, so sessions are shared.

## Fish Abbreviations

- `o` — Attach to the smortress-hosted OpenCode instance (`opencode attach http://smortress:4000`)
- On smortress itself, this connects to the local Portal server via Tailscale MagicDNS

## Model Routing

| Model | Use |
|-------|-----|
| `opencode-go/deepseek-v4-pro` | Default coding (3,450 req/5hr) |
| `opencode-go/deepseek-v4-flash` | Titles, summaries, trivial tasks (31,650 req/5hr) |
| `wafer/GLM-5.1` | Heaviest/most complex tasks (manual switch via `/model`) |
