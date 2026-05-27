// @ts-nocheck
// Auto-detects `wt switch` bash results and steers the agent to use the
// new working directory. In non-interactive sessions (agents), worktrunk
// cannot cd the shell because there's no shell integration. This extension:
//
// 1. Intercepts `wt switch` bash calls missing `--format json` and blocks
//    them with a redirect, so the agent re-issues with `--format json`.
// 2. Parses the worktree path from the output (JSON or human-readable)
//    and sends a steer message instructing the agent to use `cwd: '<path>'`
//    in subsequent bash calls.

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const WT_SWITCH_RE = /\bwt\s+switch\b/;
const WT_FORMAT_JSON_RE = /--format\s+json/;
const WT_CREATE_RE = /\b--create\b/;

// JSON format: --format json outputs {"action":"...","branch":"...","path":"..."}
const WT_JSON_PATH_RE = /"path"\s*:\s*"([^"]+)"/;

// Human-readable: "Worktree for <branch> @ <path>" or "Already on worktree for <branch> @ <path>"
const WT_HUMAN_PATH_RE = /(?:Worktree|worktree) for .+ @ (.+?)(?:,|$)/m;

function expandTilde(p: string): string {
  if (p.startsWith("~/")) {
    return path.join(os.homedir(), p.slice(2));
  }
  return p;
}

function extractWorktreePath(text: string): string | undefined {
  // Try JSON first (from --format json)
  const jsonMatch = text.match(WT_JSON_PATH_RE);
  if (jsonMatch) {
    return expandTilde(jsonMatch[1]);
  }

  // Try human-readable
  const humanMatch = text.match(WT_HUMAN_PATH_RE);
  if (humanMatch) {
    return expandTilde(humanMatch[1].trim());
  }

  return undefined;
}

export default function (pi) {
  // Intercept wt switch calls missing --format json
  pi.on("tool_call", (event) => {
    if (event.toolName !== "bash") return;

    const input = event.input;
    const command = input?.command;
    if (!command || !WT_SWITCH_RE.test(command)) return;

    // Already using --format json — let it through
    if (WT_FORMAT_JSON_RE.test(command)) return;

    // Block and tell the agent to add --format json
    return {
      block: true,
      reason:
        "Add `--format json` to the `wt switch` command so the worktree path can be parsed. " +
        "Example: `wt switch --format json --create smores/fix-foo` or `wt switch --format json main`. " +
        "This is needed because wt switch cannot change directories in non-interactive shells.",
    };
  });

  // Parse worktree path from result and steer the agent
  pi.on("tool_result", (event, ctx) => {
    if (event.toolName !== "bash") return;
    if (!event.content) return;

    const input = event.input;
    const command = input?.command;
    if (!command || !WT_SWITCH_RE.test(command)) return;

    const text = event.content
      .filter((c: any) => c.type === "text")
      .map((c: any) => c.text)
      .join("\n");

    const worktreePath = extractWorktreePath(text);
    if (!worktreePath) return;

    // Verify the path exists and is a directory
    try {
      const stat = fs.statSync(worktreePath);
      if (!stat.isDirectory()) return;
    } catch {
      return;
    }

    // Check if this was a no-op (already on the same worktree)
    const currentCwd = ctx.cwd;
    if (path.resolve(worktreePath) === path.resolve(currentCwd)) return;

    pi.sendMessage(
      {
        customType: "wt_switch_cd",
        content: `wt switch changed the worktree to ${worktreePath}. Since wt switch cannot change this session's directory (no shell integration), you MUST pass \`cwd: "${worktreePath}"\` as a parameter to all subsequent bash tool calls. Do NOT rely on \`cd\` within bash commands — use the cwd parameter instead.`,
        display: "info",
      },
      { deliverAs: "steer" },
    );
  });
}
