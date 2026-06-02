import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const PLAN_MODE_TOOLS = ["read", "bash", "grep", "find", "ls"];
const NORMAL_MODE_TOOLS = ["read", "bash", "edit", "write"];

const DESTRUCTIVE_PATTERNS = [
  /\brm\b/i,
  /\brmdir\b/i,
  /\bmv\b/i,
  /\bcp\b/i,
  /\bmkdir\b/i,
  /\btouch\b/i,
  /\bchmod\b/i,
  /\bchown\b/i,
  /\bln\b/i,
  /\btee\b/i,
  /\bdd\b/i,
  /\bnpm\s+(install|uninstall|update|ci|link|publish)/i,
  /\byarn\s+(add|remove|install|publish)/i,
  /\bpip\s+(install|uninstall)/i,
  /\bgit\s+(add|commit|push|pull|merge|rebase|reset|checkout\s+-b|stash|cherry-pick)/i,
  /\bsudo\b/i,
  /\breboot\b/i,
  /\bshutdown\b/i,
];

const SAFE_COMMANDS = [
  /^\s*cat\b/,
  /^\s*head\b/,
  /^\s*tail\b/,
  /^\s*less\b/,
  /^\s*grep\b/,
  /^\s*find\b/,
  /^\s*ls\b/,
  /^\s*pwd\b/,
  /^\s*echo\b/,
  /^\s*printf\b/,
  /^\s*wc\b/,
  /^\s*sort\b/,
  /^\s*uniq\b/,
  /^\s*diff\b/,
  /^\s*file\b/,
  /^\s*stat\b/,
  /^\s*du\b/,
  /^\s*df\b/,
  /^\s*tree\b/,
  /^\s*which\b/,
  /^\s*env\b/,
  /^\s*date\b/,
  /^\s*ps\b/,
  /^\s*uptime\b/,
  /^\s*git\s+(status|log|diff|show|branch|remote|ls-)/i,
  /^\s*curl\s/i,
  /^\s*jq\b/,
  /^\s*rg\b/,
  /^\s*fd\b/,
  /^\s*bat\b/,
];

function isSafeCommand(command: string): boolean {
  if (DESTRUCTIVE_PATTERNS.some((p) => p.test(command))) return false;
  if (SAFE_COMMANDS.some((p) => p.test(command))) return true;
  // Default deny for unknown commands in planning mode
  return false;
}

export default function (pi: ExtensionAPI) {
  let planningModeEnabled = false;

  function updateStatus(ctx: ExtensionContext) {
    if (planningModeEnabled) {
      ctx.ui.setStatus(
        "plan-mode",
        ctx.ui.theme.fg("warning", "\u23F8 planning"),
      );
    } else {
      ctx.ui.setStatus("plan-mode", undefined);
    }
  }

  function togglePlanningMode(ctx: ExtensionContext) {
    planningModeEnabled = !planningModeEnabled;
    if (planningModeEnabled) {
      pi.setActiveTools(PLAN_MODE_TOOLS);
      ctx.ui.notify(
        "Planning mode enabled. Read-only: " + PLAN_MODE_TOOLS.join(", "),
      );
    } else {
      pi.setActiveTools(NORMAL_MODE_TOOLS);
      ctx.ui.notify("Planning mode disabled. Full access restored.");
    }
    updateStatus(ctx);
  }

  pi.registerFlag("plan", {
    description: "Start in planning mode (read-only exploration)",
    type: "boolean",
    default: false,
  });

  pi.on("tool_call", async (event) => {
    if (!planningModeEnabled) return;
    if (event.toolName !== "bash") return;

    if (typeof event.input.command !== "string") return;
    if (!isSafeCommand(event.input.command)) {
      return {
        block: true,
        reason:
          "Planning mode: destructive command blocked. Use /plan off to disable.\nCommand: " +
          event.input.command,
      };
    }
  });

  pi.on("before_agent_start", async () => {
    if (planningModeEnabled) {
      return {
        message: {
          customType: "plan-mode-context",
          content:
            "[PLANNING MODE ACTIVE]\n" +
            "You are in planning mode - a read-only exploration mode for safe code analysis.\n\n" +
            "Restrictions:\n" +
            "- You can only use: read, bash, grep, find, ls\n" +
            "- Bash is restricted to READ-ONLY commands\n" +
            "- Focus on analysis, planning, and understanding\n\n" +
            "Do NOT attempt to make changes - just describe what you would do.",
          display: false,
        },
      };
    }
  });

  pi.registerCommand("plan", {
    description:
      "Plan manager: /plan on (read-only), /plan off (full access)",
    handler: async (args, ctx) => {
      const trimmedArgs = (args ?? "").trim().toLowerCase();

      if (trimmedArgs === "on") {
        if (!planningModeEnabled) togglePlanningMode(ctx);
        return;
      }
      if (trimmedArgs === "off") {
        if (planningModeEnabled) togglePlanningMode(ctx);
        return;
      }
      if (trimmedArgs === "") {
        ctx.ui.notify(
          "Usage: /plan on (read-only)  /plan off (full access)",
          "info",
        );
        return;
      }
    },
  });
}
