# Pi Extension Stack

Decision record from a full review of the pi.dev package catalog (first 20 pages,
~1000 packages, June 2026). Each category was researched via sonnet subagents
reading pi.dev package pages + GitHub repos, then picked deliberately. Managed in
`default.nix` (`piPackages` + config files).

## The stack

| Category | Package | Why |
|----------|---------|-----|
| Subagents/orchestration | `pi-subagents` (nicopreme) | 8 curated builtin agents (scout/researcher/planner/worker/reviewer/oracle/context-builder/delegate), chains + parallel + async + worktrees, acceptance contracts, per-agent model routing with fallbacks, bundled skill teaches the parent *when* to delegate. 103K/mo, by far most adopted. |
| Multi-session orchestration | `pi-agent-hub` (masta-g3) | Standalone `pi-hub` dashboard TUI that spawns real pi processes as tmux sessions – the hub is the *outer* program (replaced `pi-agent-board`, whose in-pi overlay meant double-exit friction). Ctrl+Q jumps worker→dashboard, `p` sends one-liners, hub-owned worktrees, multi-repo workspaces, per-project skills/MCP, optional MCP pool daemon. Drove the zellij→tmux migration (prefix Ctrl+N, see `features/tmux.nix`). Fallback: `@martintrojer/mu` (task DAG + crews) if structured backlogs ever needed. |
| RTK integration | `@sherif-fanous/pi-rtk` | Rewrites bash commands through `rtk` inside the bash tool (spawnHook) – invisible to the LLM, and safety/permission hooks still see the original command. No guard rules = max coverage. Single-file, zero deps. |
| Memory | `pi-hermes-memory` (chandra447) | Policy-only injection (~200-500 tokens/turn, content retrieved on demand), passive auto-learning + correction detection + auto-consolidation, built-in session search (FTS5), secret scanning before writes. 368 tests. |
| Status bar | `@wierdbytes/pi-statusline` + `@thinkscape/pi-status` | statusline: clean reorderable blocks, renders extension statuses + subagent chips, optional fixed-editor mode. pi-status: terminal title + Ghostty-native OSC 9;4 progress, zero flicker risk. History: pi-powerline-footer flickered on a recent version (despite its v0.2.2x fixedEditor/debounce fixes); pi-bar served fine but lacks git segment. Fallbacks: pi-bar (proven), wobondar `pi-footer` (max customization, medium flicker risk). |
| Structured questions | `@juicesharp/rpiv-ask-user-question` | Option previews (side-by-side code/mockups), multi-question tabs, multi-select, per-option notes. Documented headless behavior (clean `no_ui` error – board workers safe). Distinct tool name avoids the crowded `ask_user` collision family. 52K/mo. |
| Todo overlay | `@juicesharp/rpiv-todo` | Survives reload + compaction. Its state is what pi-kanban and pi-agent-hub read – ecosystem interop. |
| Side questions | `@juicesharp/rpiv-btw` | `/btw` one-off side question to same model, zero main-context pollution. rpiv suite consistency. |
| Web access | `pi-web-access` (nicopreme) | Required by pi-subagents' `researcher` builtin. Search/fetch/YouTube/GitHub. |
| Checkpoints/undo | `pi-rewind` (arpagon) | Per-tool snapshots, `/rewind`, redo stack. The yolo-mode safety net: no permission gates, instant recovery. |
| LSP/lint feedback | `pi-lsp-lite` | Same-turn diagnostics appended to write/edit results, lazy server spawn (zero startup until first edit), idle shutdown 240s, ~15-20KB parse weight, `/lsp-add` for extra servers (Nix's `nil` not preconfigured). Replaced `pi-lens` (+3.5s cold start: 63KB entry + LSP/ast-grep clients parsed every launch). Rejected `@dreki-gg/pi-lsp` (tool-only, no auto-diagnostics, 139KB) and `pi-lsp-extension` (375KB, tree-sitter WASM). GitHub-only fallbacks if ever needed: `pi-diet-lsp` (on-demand tools, ~10KB), `pi-edit-hooks` (CLI check commands, ~8KB). |
| Notifications | `pi-notify` (ferologics) | OSC 777/99/9 terminal notifications when a turn finishes – pairs with background board workers. |
| Vision | `pi-vision-proxy` (ngsoftware) | Routes images to a vision model for non-vision primaries (already assumed by APPEND_SYSTEM.md rules). |
| Programmatic tool calling | *(custom)* `extensions/code-execution.ts` | Our own Monty sandbox extension (`code_execution` tool). pi-subagents does NOT bundle one – verified. Nothing extra installed (runline etc. = second paradigm + prompt overhead for a "maybe"). |

### Carryovers (outside the category review, kept deliberately)

- `pi-mcp-adapter` – MCP server access; pi-subagents integrates with it (`mcp:` tool selectors).
- `pi-intercom` – pi-subagents auto-detects it for child→parent comms and result delivery.
- `pi-autoresearch`, `pi-review-loop` – workflow tools in active use; no conflicts with the stack.

## Deliberate non-picks

- **Permission systems** (gotgenes/pi-permission-system etc.) – safety model is
  yolo + worktrees + `pi-rewind` + external containment, not gates.
- **In-pi sandboxing** – HARD CONFLICT: both `@nqbao/pi-sandbox` and
  `pi-sandbox` override the bash tool, and so does `@sherif-fanous/pi-rtk`
  (last-one-wins). A security layer that silently loses is worse than none.
  Containment for risky work happens outside pi (nix-managed bwrap/VMs).
  If the rtk extension is ever dropped, `@nqbao/pi-sandbox` is the right pick
  (kernel-enforced, fail-closed, no prompts, macOS sandbox-exec + Linux bubblewrap).
- **Compaction/context-pruning extensions** – previously removed one; rtk +
  hermes `flushOnCompact` + pi's native compaction suffice.
- **Goal/looping, observability, session managers, themes, voice, chat bridges** – bloat for this workflow.
- **Knowledge search** (`pi-knowledge-search`) – skipped; add standalone later if
  a notes vault needs agent access (no conflicts with hermes).

## Fallbacks (researched, documented, not installed)

| If this disappoints | Switch to |
|---------------------|-----------|
| pi-agent-board (young: v0.2.0, ~900/mo) | `pi-agent-hub` (tmux hub, first-class multi-repo workspaces + hub-owned worktrees), then `@martintrojer/mu` (tmux crew + task DAG, for structured backlogs) |
| pi-hermes-memory | `gentle-engram` (cross-agent MCP memory; needs Go binary, agent-discipline saves) |
| rpiv-ask-user-question | `@eko24ive/pi-ask` (more features: @-file refs, /answer extraction; generic `ask_user` name, undocumented headless) |
| @sherif-fanous/pi-rtk | `@mrclrchtr/supi-rtk` (same mechanism + guards that skip known-lossy rg/biome/lint rewrites) |
| pi-bar | `@narumitw/pi-statusline` (statuses on dedicated second line, fixed segments) |
| pi-subagents (mega-fanout need) | `@quintinshaw/pi-dynamic-workflows` per-project only (JS code-mode orchestration, journaled resume) – never globally alongside pi-subagents |

Optional later add-on: `pi-hud` in *overlay* mode (live pi-subagents run status;
stacks on pi-bar since overlay doesn't replace the footer).

## Cross-extension interaction map

- **bash tool**: owned solely by `@sherif-fanous/pi-rtk`. Never install another
  bash-tool override (lean-ctx, hashline bash, tmux-bash, sandboxes).
- **footer**: owned by `@wierdbytes/pi-statusline`; it renders other
  extensions' `setStatus` entries (rtk indicator etc.) and pi-subagents chips.
  One footer extension max. `@thinkscape/pi-status` is title-bar-only – stacks
  safely.
- **tool names**: no collisions – `ask_user_question` (rpiv), `memory*`/
  `session_search`/`skill` (hermes), `subagent`/`chain`/`parallel`
  (pi-subagents), `code_execution` (custom).
- **Esc+Esc**: settings `doubleEscapeAction = "tree"` wins; use `/rewind`
  command for pi-rewind instead of its double-esc shortcut.
- **headless board workers**: load the full global stack. rpiv tools error
  cleanly (`no_ui`), pi-bar/rewind stay dormant, hermes runs its reviews
  (cheap model via `llmModelOverride`), rtk rewriting active. All verified safe.
- **subagent children (SDK)**: do NOT load the extension stack – no per-child
  injection tax from hermes/rpiv/etc.

## Config knobs (where things live)

- `~/.pi/agent/settings.json` – nix-managed; `subagents.agentOverrides` does the
  aggressive model tiering (scout/researcher/worker/delegate → weak tier;
  planner/reviewer/oracle/context-builder → strong tier).
- `~/.pi/agent/hermes-memory-config.json` – nix-managed; policy-only mode,
  `llmModelOverride` pinned to the weak tier so background reviews stay cheap.
- `~/.pi/agent/pi-bar.json` – NOT nix-managed (pi-bar persists `/bar` toggles
  there; clobbering it would fight the TUI). Tune via `/bar`, `/bar status`,
  `/bar segments hide progress`.
- `AGENT_BOARD_SUMMARY_MODEL` – env var (fish conf.d); board row summaries on
  the weak tier. `off` disables.
- `APPEND_SYSTEM.md` – carries the delegation nudge + acceptance-contract rule
  (the "push to use subagents" requirement; pi-subagents' bundled skill does the
  detailed teaching).
- Acceptance contracts: opt-in per delegation; the pi-subagents skill
  auto-applies them when handing a plan/spec to a worker. No extra config.
- pi-vision-proxy: needs a vision model configured post-install (see its README)
  – pointing at the weak tier vision-capable model.

## Round 2 (second catalog pass: git/vcs, background, remotes, hygiene, rendering, steering, fun)

| Category | Pick | Why |
|----------|------|-----|
| Git/VCS | *(none yet)* | User is on plain git (not jj). Category deferred – see rejections + safe options below. `pi-jj-git-align` is the pick IF jj is ever adopted. |
| Background tasks | `pi-background-tasks` (ismailsaleekh) | `bg_run`/`bg_status`/`bg_logs`/`bg_kill` + completion wakeups + Shift+Down dock + child-pi telemetry. New tools, NOT a bash override → rtk-safe. No tmux. Headless-safe. |
| Web remote | *(keep)* `@blackbelt-technology/pi-agent-dashboard` | Incumbent won its own category review: most mature (151 stars), non-TUI-interfering SSE mirror, sees board sessions. Optional later: `tau-mirror` read-only PWA. |
| Session browse | *(built-in)* | `pisesh` dropped: +1.5s startup for features mostly covered by pi's `/resume` picker + hermes `session_search`. |
| Session naming | `pi-autoname` | Light auto-naming: first dialogue + 30min cooldown re-names, weak-tier model + fallbacks (nix-managed `pi-autoname.json`), `respectManualName: true` so `/name` stays sticky, `/autoname` for manual. Caveat: MIT + auditable source in tarball, but no public repo. Rejected `@agnishc/edb-auto-name-session` (hardcoded opencode/big-pickle – provider we don't run) and running two naming tools (`@tifan/pi-rename` dropped – naming tools race). |
| Tool rendering | `pi-tool-display` | Display-only (verified: execute delegates to SDK untouched → model sees raw results, rtk-safe), rich diffs, per-tool ownership toggles, RTK-compaction hints, best tested. |
| Steering | `@agnishc/edb-agent-steer` | Native one-at-a-time steering already covers queueing; this only adds Enter→s/q/d/e menu (discard option), no keybindings/widgets. All queue extensions rejected as redundant. |
| Fun / cosmetics | custom `extensions/splash.ts` + `pi-animations` | Splash: custom extension using `ctx.ui.setHeader` (non-modal – type immediately, no dismiss key) with nancyj-fancy figlet banner in theme accent + model/extension/skill/tool counts; fresh sessions only, clears on first message. Replaced `@codesook/pi-welcome-screen`: modal overlay required Enter/Esc to dismiss (and its Esc check missed kitty-protocol `\x1b[27u`); `ghoseb/pi-splash` had the right setHeader approach but wrong content. Animations: 1-line only (multi-line fights statusline's above-editor space), seeded pacman/plasma-wave/pipeline, change via `/animation showcase`. Avatar/pet niche closed: `pi-pokepet` (not worth it) and `pi-emote` (broke alongside agent-board; zellij ASCII-only) both tried and removed; exhaustive search found nothing better. Working-line alternates documented: `@dustydonkey/pi-spinner`, `pi-working-vibe`. |

### Round 2 rejections worth remembering

- **Git/VCS category deferred** (user on plain git, no jj). Notes from review,
  valid for plain git: commit automation candidates = pi-committer (subagent
  commit splitting, opt-in per project) or @eamode/pi-commit (/autocommit);
  pi-graphite only if adopting Graphite stacked PRs; @spences10/pi-git-ui uses
  j/k nav (keybinding constraint). If jj ever adopted: pi-jj-git-align, and the
  whole commit-automation family becomes hazardous (bookmark drift).
- **Worktree extensions BLOCKED by rtk**: @lanquarden/pi-dev-worktrees
  *documents* incompatibility with @sherif-fanous/pi-rtk's spawnHook;
  @season179/pi-worktree same mechanism. Worktrees come from pi-subagents +
  pi-agent-board instead.
- **pi-unified-exec**: unique REPL/ssh stdin driving, but removes builtin bash
  by default (rtk conflict without `--keep-builtin-bash`). Revisit if PTY
  driving becomes a need.
- **pi-session-cleanup**: good tool (trash-first batch delete) but deferred –
  bulk deletes leave stale rows in hermes' FTS session index. Add later if
  session sprawl hurts; reindex hermes after use.
- **Steering queue extensions** (@dhruv2mars/pi-queue, pi-message-queue,
  prompt stashes): redundant with native `one-at-a-time` modes +
  Enter/Alt+Enter/Alt+Up.
- **pi-show-diffs**: gates edits – anti-yolo. **pi-pretty**: owns find/grep
  execution (bundled FFF), not pure rendering.
- **pi-pompom**: ships its own footer (pi-bar collision) + paid TTS + LLM
  side-chat token costs. Charming but incompatible.
- GitHub-side tools (`@gotgenes/pi-github-tools`, `pi-gh-cli`) are SAFE with jj
  (remote-state only) – not installed, add if agent-driven GitHub ops wanted.

## Decision context worth remembering

- "Curated, not authored": pi-subagents was the only orchestrator shipping a
  full curated agent roster; gotgenes/tintinweb forks ship 3 generic agents and
  expect authored .md files.
- pi-agent-board chosen over tmux options specifically for: background-first
  dispatch (must-have), agent-view UX, no multiplexer dependency. Immaturity
  accepted ("immature is fine if it works well").
- Board dispatch uses a reasonably-smart model by default – initial work is
  discovery/planning, not worth a cheap-model guard.
- rtk full-coverage risk accepted: lossy `rg` rewrites possible; escapes are
  `RTK_DISABLED=1 <cmd>` and `/rtk disable`.
- pi-powerline-footer dropped from the old stack for real-world flicker.
- pi-total-recall replaced by hermes: 8KB/session injection vs policy-only,
  no auto-learning, no secret scanning. `pi-rtk-optimizer` replaced by
  sherif-fanous: tool_call-hook rewriting breaks permission-hook visibility and
  its output compaction can break edits.
