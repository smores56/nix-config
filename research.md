# Research: Pi tooling for viewing FULL subagent output live

## Summary

For viewing full live output from `pi-subagents` (nicopreme), the **built-in Ctrl+O** already expands complete streaming transcripts in-place. For a dedicated overlay/pane, **@tintinweb/pi-subagents** offers a live-scrolling conversation viewer opened via `/agents`, but it's a separate subagent system. For web-based viewing, **@blackbelt-technology/pi-agent-dashboard** provides full transcript mirroring with subagent inspector popouts. No arrow-key-only tools found; all meet the constraint.

## Findings

### 1. Built-in: nicopreme's pi-subagents + Ctrl+O (already installed)

**What it shows:** Full streaming transcript expansion in the parent conversation.

**Evidence from pi.dev/packages/pi-subagents:**
> "Foreground runs show compact live progress for single, chain, and parallel modes: current tool, recent output, token counts, duration, activity freshness, current-tool duration, and chain graph metadata when available.
>
> Press `Ctrl+O` to expand the full streaming view with complete output per step."

**How it works:**
- Foreground runs stream in the parent conversation by default (compact view)
- `Ctrl+O` expands to show full output per step
- Background runs: check via `subagent({ action: "status" })` or read `.pi/subagent-artifacts/{runId}_{agent}.jsonl` session files

**Pros:** Zero install cost (already running), native to pi-subagents, arrow keys work (Ctrl+O is not h/j/k/l)
**Cons:** Expands in-place in the conversation, not a dedicated pane; background runs require status polling or file tailing

**Constraints check:**
- ✅ Arrow keys: Ctrl+O uses control modifier, not vim-style navigation
- ✅ Startup cost: 0ms (already loaded)
- ✅ No conflicts: doesn't touch footer or bash tool

---

### 2. Dedicated overlay: @tintinweb/pi-subagents conversation viewer

**What it shows:** Live-scrolling overlay of a subagent's full conversation (auto-follows new content, scroll up to pause).

**Evidence from pi.dev/packages/@tintinweb/pi-subagents:**
> "**Conversation viewer** — select any agent in `/agents` to open a live-scrolling overlay of its full conversation (auto-follows new content, scroll up to pause). Stop a still-running agent from here by pressing `x` (then `x` again to confirm) — works for background agents too."

**How it works:**
- Open `/agents` command
- Select a running subagent from the list
- Live overlay renders full transcript in real-time
- `x` (confirm) to stop a running agent from the viewer

**Pros:** Dedicated viewer pane, live updates, can stop agents, works with background agents
**Cons:** **Different subagent system** – uses `Agent` tool, not nicopreme's `subagent` tool; would require running two parallel subagent extensions or switching systems entirely

**Constraints check:**
- ✅ Arrow keys: Uses arrow keys for navigation in `/agents` picker
- ⚠️ Startup cost: ~1-2s extension load (typical for tool-heavy extensions)
- ⚠️ Conflict risk: Registers its own `Agent` tool; could coexist with `pi-subagents` but they don't share child sessions

**Compatibility note:** This is a **separate subagent implementation**. It cannot view nicopreme's pi-subagents children – it only views agents spawned via its own `Agent` tool. To use this, you'd need to either:
- Run both extensions (tool name collision: both want to be "the" subagent tool)
- Switch from nicopreme's pi-subagents to @tintinweb/pi-subagents entirely

---

### 3. Web dashboard: @blackbelt-technology/pi-agent-dashboard

**What it shows:** Real-time web dashboard with full session mirroring, subagent inspector with popout support.

**Evidence from pi.dev/packages/@blackbelt-technology/pi-agent-dashboard:**
> "**Real-time session mirroring** — all active pi sessions with live streaming messages
>
> **pi-flows integration** — Live flow execution dashboard with agent cards, detail views, flow graph visualization, summary, abort/auto controls. Launch flows and design new ones with the Flow Architect — all from the browser. Fork decisions and subagent dialogs forwarded via PromptBus."
>
> From BlackBeltTechnology/pi-dashboard-subagents:
> "Spawns subagents **in-memory** ... and emits **every event, tool call, and reasoning step** as a structured timeline the pi-agent-dashboard can render in its subagent inspector and pop out into a new tab."

**How it works:**
- Install `pi install npm:@blackbelt-technology/pi-agent-dashboard`
- Bridge extension auto-starts dashboard server at http://localhost:8000
- Open browser; all active pi sessions appear automatically
- Subagent inspector shows full timeline, can pop out to new tab
- **Requires pi-dashboard-subagents extension** (foreground-only, different from nicopreme's pi-subagents)

**Pros:** Web UI (mobile-friendly), multi-session view, subagent inspector with popout, integrated terminal/diff viewer
**Cons:** Separate server (auto-started), web-only (no TUI pane), **requires its own pi-dashboard-subagents** (not compatible with nicopreme's pi-subagents out of box)

**Constraints check:**
- ✅ Arrow keys: Web UI uses mouse/touch, no vim keybindings
- ⚠️ Startup cost: ~2-3s for bridge extension + server auto-start
- ✅ No conflicts: Separate server, doesn't touch pi footer/bash

**Compatibility note:** Works with `pi-dashboard-subagents` (foreground-only, emits timeline events). For nicopreme's pi-subagents, you'd see the parent session's messages in the dashboard but **not** the subagent's internal transcript unless pi-dashboard-subagents is used instead.

---

### 4. Alternative TUI overlay: MonsieurBarti/sub-agents-pi

**What it shows:** Three-tier TUI with interactive overlay panel showing live tool calls.

**Evidence from GitHub MonsieurBarti/sub-agents-pi:**
> "**👀 Live TUI spying** — Watch tool calls stream in real-time with a three-tier UI
>
> **📊 Three-tier UI** — Scrollback row, bottom widget counter, interactive overlay panel
>
> **Overlay panel** — Rich interactive view opened with `ctrl+shift+s`
>
> The panel shows a two-pane view: list of sub-agents on the left, live detail on the right. Tool calls stream in real-time, usage stats update live."
>
> From the scrollback:
> "Press `Ctrl+O` to expand and see the full transcript, all tool calls, and the final message rendered as Markdown."

**How it works:**
- Install `pi install npm:@the-forge-flow/sub-agents-pi`
- Use `tff-subagent` tool (not nicopreme's `subagent`)
- `Ctrl+Shift+S` opens overlay panel
- Two-pane view: list left, live detail right
- ↑↓ navigate, Enter to zoom, `k` to kill

**Pros:** Dedicated TUI overlay, two-pane layout, live streaming, can kill agents
**Cons:** **Different tool** (`tff-subagent` not `subagent`); ad-hoc agent spawning (no agent registry); cannot view nicopreme's pi-subagents children

**Constraints check:**
- ✅ Arrow keys: Uses ↑↓ for navigation, Ctrl+Shift+S for panel
- ⚠️ Startup cost: ~1-2s typical extension load
- ✅ No conflicts: Namespaced as `tff-subagent`

**Compatibility note:** This is a **separate subagent implementation** for ad-hoc spawning. It will **not** show nicopreme's pi-subagents output. You'd need to switch tools entirely.

---

### 5. Partial overlay: pi-subagent-in-memory

**What it shows:** Detail overlay for in-memory subagents with latest 5 lines.

**Evidence from pi.dev/packages/pi-subagent-in-memory:**
> "### 🔍 Subagent Detail Overlay (`Ctrl+N`)
>
> Press **Ctrl+1** through **Ctrl+9** to open a detail popup for the **N-th visible** subagent card (1 = leftmost/topmost in the current window):
>
> - **Prompt** — Full prompt text with word wrapping (up to 5 lines)
> - **Messages** — Live-updating stream of the subagent's activity (text output, tool calls, status changes), always showing the latest 5 lines
> - Press the same **Ctrl+N** shortcut or **Escape** to close the overlay"

**How it works:**
- Install `pi install npm:pi-subagent-in-memory`
- Use `subagent_create` tool (in-memory, not subprocess)
- Cards render above editor
- Ctrl+1-9 opens detail popup

**Pros:** Lightweight overlay, shows live activity, in-memory execution
**Cons:** **Only latest 5 lines** (not full transcript); different tool (`subagent_create` not nicopreme's `subagent`); in-memory architecture (no session files)

**Constraints check:**
- ✅ Arrow keys: Ctrl+N with number keys
- ⚠️ Startup cost: ~0.5-1s (lighter than most)
- ✅ No conflicts: Different tool name

**Compatibility note:** Cannot view nicopreme's pi-subagents output. You'd need to use `subagent_create` instead.

---

### 6. Status overlay only: pi-hud

**What it shows:** Subagent activity summary (counts, task labels, elapsed time) in right-side or footer HUD.

**Evidence from pi.dev/packages/pi-hud:**
> "Live subagent status:
> - running/done/error counts;
> - active task label;
> - elapsed time;
> - token/context count when available."

**How it works:**
- Install `pi install npm:pi-hud`
- Auto-starts visible on session start
- Shows subagent counters, not full output
- `/hud` to toggle, `Ctrl+Shift+H` to show/hide

**Pros:** Persistent status, minimal visual footprint, footer mode available
**Cons:** **Status lines only** – not full transcript; no detail view

**Constraints check:**
- ✅ Arrow keys: Ctrl+Shift+H and Ctrl+H for shortcuts
- ⚠️ Startup cost: ~0.3-0.5s (visible startup notice by default)
- ⚠️ Footer conflict: Footer mode replaces pi's built-in footer (conflicts with @wierdbytes/pi-statusline if that's installed)

**Compatibility note:** Works with nicopreme's pi-subagents for status counters. **Does not show full transcript**.

---

### 7. Manual: tail session JSONL files

**What it shows:** Full raw event stream in a second terminal.

**Evidence from nicopreme's pi-subagents docs:**
> "Session files are stored under a per-run session directory. With `context: "fork"`, each child starts with `--session <branched-session-file>` produced from the parent's current leaf...
>
> Debug artifacts live under `{sessionDir}/subagent-artifacts/` or a user-scoped temp artifact directory. Per task you may see:
> - `{runId}_{agent}_input.md`
> - `{runId}_{agent}_output.md`
> - `{runId}_{agent}.jsonl`
> - `{runId}_{agent}_meta.json`
>
> Async completions ... write:
> ```
> <tmpdir>/pi-subagents-<scope>/async-subagent-runs/<id>/
>   status.json
>   events.jsonl
>   output-<n>.log
>   subagent-log-<id>.md
> ```"

**How it works:**
```bash
# Find session dir (check parent session output for path)
tail -f ~/.pi/agent/sessions/subagent/{runId}_{agent}.jsonl
# or
tail -f /tmp/pi-subagents-$(whoami)/async-subagent-runs/{id}/events.jsonl
```

**Pros:** Works immediately, no install, shows raw events
**Cons:** Manual file discovery, JSONL format (not rendered), separate terminal

**Constraints check:**
- ✅ All constraints: No keybindings, no extension conflicts
- ✅ Startup cost: 0ms

---

## Sources

### Kept

- **pi-subagents (nicopreme)** – https://pi.dev/packages/pi-subagents – Ctrl+O for full streaming view built-in; session JSONL files for manual tailing. Authority source for the installed extension.
- **@tintinweb/pi-subagents** – https://pi.dev/packages/@tintinweb/pi-subagents – Live conversation viewer overlay via `/agents`; separate subagent tool incompatible with nicopreme's.
- **@blackbelt-technology/pi-agent-dashboard** – https://pi.dev/packages/@blackbelt-technology/pi-agent-dashboard – Web dashboard with subagent inspector; requires pi-dashboard-subagents (different tool).
- **MonsieurBarti/sub-agents-pi** – https://github.com/MonsieurBarti/sub-agents-pi – Three-tier TUI with Ctrl+Shift+S overlay; separate `tff-subagent` tool.
- **pi-subagent-in-memory** – https://pi.dev/packages/pi-subagent-in-memory – Ctrl+1-9 detail overlay with latest 5 lines; different tool.
- **pi-hud** – https://pi.dev/packages/pi-hud – Status counters only, not full transcript; footer mode conflicts with pi-statusline.

### Dropped

- **agent-viewer (mrexodia/agent-viewer)** – Generic Go-based JSONL viewer for Pi and Claude Code; not a pi extension, requires separate server.
- **pi-monitor (gregjohnso)** – Event-driven shell monitoring for pi, not subagent output viewing.
- **@psg2/pi-transcript** – Converts pi sessions to HTML transcripts post-facto, not live viewing.

---

## Gaps

**No native "open subagent in separate pane" for nicopreme's pi-subagents.** The built-in Ctrl+O expands in-place. To get a dedicated overlay/pane with nicopreme's tool, you'd need to build a custom extension or use one of the alternative subagent systems.

**Cross-tool incompatibility.** The best overlays (@tintinweb/pi-subagents conversation viewer, MonsieurBarti/sub-agents-pi panel, pi-subagent-in-memory detail popup) are tied to their own subagent implementations. They cannot view children spawned by a different tool.

**Web dashboard limitations.** @blackbelt-technology/pi-agent-dashboard has the richest UI but requires switching to pi-dashboard-subagents or running a custom bridge to emit the timeline events it expects.

---

## Recommended ladder

**If you want to keep nicopreme's pi-subagents:**

1. **Use built-in Ctrl+O** – Zero cost, full streaming view, expands in conversation. Already installed.
2. **Tail session JSONL files** – Manual but shows raw events. No install needed.
   ```bash
   # Find path from parent output, then:
   tail -f {sessionDir}/subagent-artifacts/{runId}_{agent}.jsonl
   ```
3. **Install pi-hud for status overview** – Persistent counters/labels (no full transcript).
   ```bash
   pi install npm:pi-hud
   ```

**If you want a dedicated overlay and are willing to switch subagent tools:**

1. **@tintinweb/pi-subagents** – Best dedicated viewer: live-scrolling overlay via `/agents`, can stop agents, works with background runs.
   ```bash
   pi remove npm:pi-subagents           # Remove nicopreme's
   pi install npm:@tintinweb/pi-subagents
   ```
   Trade-off: Different `Agent` tool syntax, loses nicopreme's chains/parallel/clarify features.

2. **MonsieurBarti/sub-agents-pi** – Two-pane Ctrl+Shift+S overlay, ad-hoc spawning, namespaced tool (`tff-subagent`) so it can coexist, but you'd be running two subagent systems.
   ```bash
   pi install npm:@the-forge-flow/sub-agents-pi
   ```

**If you want a web dashboard:**

1. **@blackbelt-technology/pi-agent-dashboard** – Full web UI, multi-session, mobile-friendly. Works with pi-dashboard-subagents (foreground-only).
   ```bash
   pi install npm:@blackbelt-technology/pi-agent-dashboard
   # Auto-starts server at http://localhost:8000
   ```
   Trade-off: Requires switching to pi-dashboard-subagents or custom bridge integration.

---

## Next steps

- **Try Ctrl+O** first – it's already available and may meet the need.
- **Evaluate @tintinweb/pi-subagents** in a test session to see if the conversation viewer UX justifies switching tools.
- **Check constraints:** Confirm @wierdbytes/pi-statusline and @sherif-fanous/pi-rtk are installed before testing pi-hud footer mode (will conflict).
