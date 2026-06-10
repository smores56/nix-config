/**
 * Minimal splash header: nancyj-fancy "smores" banner + basic session info.
 *
 * Non-modal (ctx.ui.setHeader) - type immediately, no dismiss key needed.
 * Shows on fresh sessions only; clears on first user message / agent start.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const BANNER = [
  ".d8888b. 88d8b.d8b. .d8888b. 88d888b. .d8888b. .d8888b.",
  "Y8ooooo. 88'`88'`88 88'  `88 88'  `88 88ooood8 Y8ooooo.",
  "      88 88  88  88 88.  .88 88       88.  ...       88",
  "`88888P' dP  dP  dP `88888P' dP       `88888P' `88888P'",
];

export default function splash(pi: ExtensionAPI) {
  let active = false;

  const dismiss = (ctx: any) => {
    if (!active) return;
    active = false;
    ctx.ui.setHeader(undefined);
  };

  pi.on("session_start", async (_event: any, ctx: any) => {
    if (!ctx.hasUI) return;

    // pi-animations replaces the working *message*, but pi core still draws
    // its braille spinner prefix next to it (and pushes the full-width
    // animation into a wrap). Hide the built-in indicator entirely.
    ctx.ui.setWorkingIndicator?.({ frames: [] });

    // Fresh sessions only - skip resumes/branches that already have messages.
    const branch = ctx.sessionManager?.getBranch?.() ?? [];
    if (branch.some((e: any) => e.type === "message")) return;

    const commands = pi.getCommands?.() ?? [];
    const extensions = new Set(
      commands
        .filter((c: any) => c.source === "extension")
        .map((c: any) => c.sourceInfo?.path),
    ).size;
    const skills = new Set(
      commands
        .filter((c: any) => c.source === "skill")
        .map((c: any) => c.sourceInfo?.path),
    ).size;
    const tools = (pi.getAllTools?.() ?? []).filter(
      (t: any) => t.sourceInfo?.source !== "builtin",
    ).length;

    active = true;
    ctx.ui.setHeader((_tui: any, theme: any) => ({
      render(width: number): string[] {
        const model = ctx.model?.name ?? "no model";
        const thinking = ctx.model?.reasoning
          ? ` · ${pi.getThinkingLevel?.() ?? ""}`
          : "";
        const info = theme.fg(
          "muted",
          `${model}${thinking} · ${extensions} extensions · ${skills} skills · ${tools} tools`,
        );
        const lines: string[] = [""];
        if (width > 56) {
          for (const row of BANNER) lines.push(theme.fg("accent", row));
          lines.push("");
        }
        lines.push(info);
        lines.push("");
        return lines;
      },
    }));
  });

  pi.on("user_message", async (_event: any, ctx: any) => dismiss(ctx));
  pi.on("agent_start", async (_event: any, ctx: any) => dismiss(ctx));
  pi.on("session_shutdown", async (_event: any, ctx: any) => dismiss(ctx));
}
