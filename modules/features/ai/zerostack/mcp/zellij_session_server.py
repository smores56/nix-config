#!/usr/bin/env python3
"""
zerostack zellij-session MCP server.

Exposes one tool, `start_zerostack_session`, that lets a running zerostack
agent hand off a sub-task to a NEW zerostack session in a fresh Zellij tab on
its own git worktree. Mirrors the behavior of maki's
`start_worktree_session.lua` but on zerostack's extension surface (MCP) instead
of a Lua tool registry. Designed to be invoked from inside a zerostack TUI run.

Flow per tool call:
  1. `agent-branch-name --slug <slug> --task "<task>"` (caller-side; this server
     only consumes the resulting branch + prompt).
  2. `wt switch --create <branch> --format json` -> {"path": "..."} worktree.
  3. `zellij action new-tab -n <name> -c <path> --close-on-exit -- zerostack -- "$PROMPT"`
     (interactive TUI; the prompt is the new session's first user message).

The prompt is passed via the `ZS_START_PROMPT` env var (never the command line)
to avoid `ps`/history exposure and shell-quoting risk, exactly like maki's
START_PROMPT pattern.

MCP transport: stdio JSON-RPC 2.0 (2024-11-05). No third-party deps — the repo
already ships plain-Python helpers (see ../../maki/codex-cred-sync.py).
Managed by home-manager (modules/features/ai/zerostack). Manual edits are clobbered.
"""

import json
import os
import subprocess
import sys


def _send(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def _log(msg: str) -> None:
    # MCP servers share stderr with the host; zerostack surfaces connection
    # errors there. Keep it one-line so logs stay greppable.
    sys.stderr.write(f"[zellij-session] {msg}\n")
    sys.stderr.flush()


def _shell_quote(s: str) -> str:
    return "'" + s.replace("'", "'\\''") + "'"


def _rpc_error(req_id, code: int, message: str) -> None:
    _send({"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}})


# --- tool handlers --------------------------------------------------------- #

TOOL_SCHEMA = {
    "type": "object",
    "required": ["branch", "prompt"],
    "properties": {
        "branch": {
            "type": "string",
            "description": (
                "Full git branch name (e.g. 'smores/my-feature'). Generate via "
                "`agent-branch-name --slug <slug> --task \"<task>\" --dry-run` BEFORE "
                "calling this tool; this server consumes the resolved branch."
            ),
        },
        "prompt": {
            "type": "string",
            "description": (
                "Full initial prompt for the new zerostack session (becomes its first "
                "user message). E.g. 'Implement user authentication with OAuth2'."
            ),
        },
        "task": {
            "type": "string",
            "description": "Short display label for the Zellij tab name (defaults to the branch's last path segment).",
        },
        "yolo": {
            "type": "boolean",
            "description": "Run the spawned zerostack with --yolo (auto-accept non-destructive ops). Default: true.",
        },
    },
}


def _spawn_session(branch: str, prompt: str, task: str | None, yolo: bool) -> str:
    """Create the worktree and spawn a zerostack TUI in a new Zellij tab.

    Returns a one-paragraph human summary for the calling agent. The zellij tab
    is the long-lived unit; this function returns as soon as the tab is opened.
    """
    worktree_name = branch.rsplit("/", 1)[-1] or branch
    tab_label = (task or worktree_name).strip() or worktree_name
    yolo_flag = "--yolo" if yolo else ""

    # Phase 1 — resolve the worktree path. `wt switch --create` fails with a
    # human-readable message when the branch already exists; retry without
    # --create in that case. JSON is emitted on the first stdout line on success;
    # the rest is human status that we discard.
    resolve_script = f"""
set -euo pipefail
branch={_shell_quote(branch)}
wt_output=$(wt switch --create "$branch" --format json 2>&1) || {{
  case "$wt_output" in
    *"already exists"*)
      wt_output=$(wt switch "$branch" --format json 2>&1) || {{ echo "ERR:$wt_output"; exit 1; }}
      ;;
    *)
      echo "ERR:$wt_output"
      exit 1
      ;;
  esac
}}
path=$(printf '%s' "$wt_output" | head -n1 | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('path',''))" 2>/dev/null) || path=""
if [ -z "$path" ]; then
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root=""
  if [ -n "$root" ]; then
    path="$root/.worktrees/{worktree_name}"
  fi
fi
if [ -z "$path" ]; then
  echo "ERR:could not determine worktree path from wt output: $wt_output"
  exit 1
fi
printf '%s' "$path"
"""
    try:
        resolve = subprocess.run(
            ["bash", "-c", resolve_script],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=20,
        )
    except FileNotFoundError as e:
        raise RuntimeError(f"required binary missing on PATH: {e.filename}") from e
    except subprocess.TimeoutExpired as e:
        raise RuntimeError("worktree creation timed out") from e
    if resolve.returncode != 0:
        err = (resolve.stdout or "").removeprefix("ERR:")
        err = err or resolve.stderr or "unknown wt error"
        raise RuntimeError(f"worktree creation failed: {err.strip()}")
    path = resolve.stdout.strip()
    if not path:
        raise RuntimeError("worktree path came back empty")

    # Phase 2 — open the zerostack TUI in a new Zellij tab. Detached: we don't
    # wait on the tab (it's interactive and long-lived). `ZS_START_PROMPT` carries
    # the prompt out of argv. The spawned zerostack inherits this process's env
    # (incl. the API keys allow-listed by the nono profile), so it reads the same
    # ~/.config/zerostack/config.toml the parent uses.
    if not os.environ.get("ZELLIJ_SESSION_NAME"):
        # Not inside zellij — still created the worktree, just can't open a tab.
        return (
            f"Created worktree `{path}` (branch `{branch}`) but no Zellij session is active "
            f"(ZELLIJ_SESSION_NAME unset); cannot open a new tab. Run `zellij` and retry, "
            f"or `cd {path} && zerostack`."
        )

    spawn_cmd = (
        f"zellij action new-tab -n {_shell_quote(tab_label)} -c {_shell_quote(path)} "
        f"--close-on-exit -- zerostack {yolo_flag} -- \"$ZS_START_PROMPT\""
    )
    env = os.environ.copy()
    env["ZS_START_PROMPT"] = prompt
    try:
        spawn = subprocess.run(
            ["bash", "-c", spawn_cmd],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10,
            start_new_session=True,  # detach so the tab outlives this MCP call
        )
    except subprocess.TimeoutExpired:
        # `zellij action new-tab` blocks while the new tab is foreground in some
        # layouts. A timeout here usually means the tab opened fine; treat as
        # soft success rather than failing the handoff.
        return (
            f"Opened Zellij tab **{tab_label}** running zerostack "
            f"(`zellij action` did not return in 10s; tab likely live).\n"
            f"- Branch: `{branch}`\n- Worktree: `{path}`"
        )
    if spawn.returncode != 0:
        raise RuntimeError(
            f"zellij tab spawn failed (exit {spawn.returncode}): "
            f"{(spawn.stderr or spawn.stdout).strip()}"
        )
    return (
        f"Started zerostack session in Zellij tab **{tab_label}**\n"
        f"- Branch: `{branch}`\n- Worktree: `{path}`"
    )


# --- MCP dispatch ---------------------------------------------------------- #

def _handle_call(req_id, params: dict) -> None:
    name = params.get("name")
    args = params.get("arguments") or {}
    if name != "start_zerostack_session":
        _rpc_error(req_id, -32601, f"unknown tool: {name}")
        return
    branch = (args.get("branch") or "").strip()
    prompt = args.get("prompt") or ""
    task = args.get("task")
    yolo = bool(args.get("yolo", True))
    if not branch or not prompt:
        _rpc_error(req_id, -32602, "branch and prompt are required and non-empty")
        return
    try:
        summary = _spawn_session(branch, prompt, task, yolo)
        _send({
            "jsonrpc": "2.0", "id": req_id,
            "result": {"content": [{"type": "text", "text": summary}]},
        })
    except Exception as e:
        _log(f"tool error: {e}")
        _send({
            "jsonrpc": "2.0", "id": req_id,
            "result": {
                "content": [{"type": "text", "text": f"error: {e}"}],
                "isError": True,
            },
        })


def main() -> None:
    # MCP servers must not print anything but JSON-RPC frames to stdout.
    # Read line-delimited JSON from stdin; respond synchronously per request.
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        method = msg.get("method")
        req_id = msg.get("id")
        if method == "initialize":
            _send({
                "jsonrpc": "2.0", "id": req_id,
                "result": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "zellij-session", "version": "0.1.0"},
                },
            })
        elif method == "notifications/initialized":
            pass
        elif method == "tools/list":
            _send({
                "jsonrpc": "2.0", "id": req_id,
                "result": {"tools": [{
                    "name": "start_zerostack_session",
                    "description": (
                        "Spawn a NEW interactive zerostack session in a fresh Zellij tab on a "
                        "dedicated git worktree, with a given starting prompt. Use to hand off "
                        "a long-horizon subtask to an isolated sibling zerostack instead of "
                        "doing it inline. The caller is responsible for resolving a branch name "
                        "first via `agent-branch-name --slug <slug> --task \"<task>\" --dry-run`. "
                        "The new tab runs the zerostack TUI; its working directory is the "
                        "worktree root, and the prompt becomes the session's first user message."
                    ),
                    "inputSchema": TOOL_SCHEMA,
                }]},
            })
        elif method == "tools/call":
            _handle_call(req_id, msg.get("params") or {})
        elif req_id is not None:
            # Unknown request with an id: respond so the client doesn't hang.
            _send({"jsonrpc": "2.0", "id": req_id, "result": {}})


if __name__ == "__main__":
    main()
