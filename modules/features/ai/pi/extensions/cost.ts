import { getAgentDir } from "@earendil-works/pi-coding-agent";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import * as fs from "node:fs/promises";
import * as path from "node:path";

interface CostEntry {
  cost: number;
  model: string;
  date: string;
}

async function extractCosts(filePath: string): Promise<CostEntry[]> {
  const entries: CostEntry[] = [];
  let content: string;
  try {
    content = await fs.readFile(filePath, "utf-8");
  } catch {
    return entries;
  }

  for (const line of content.split("\n")) {
    if (!line.trim()) continue;
    let entry: unknown;
    try {
      entry = JSON.parse(line);
    } catch {
      continue;
    }
    if (
      entry &&
      typeof entry === "object" &&
      "type" in entry &&
      (entry as Record<string, unknown>).type === "message" &&
      "message" in entry
    ) {
      const msg = (entry as Record<string, unknown>).message;
      if (
        msg &&
        typeof msg === "object" &&
        "role" in msg &&
        (msg as Record<string, unknown>).role === "assistant" &&
        "usage" in msg
      ) {
        const usage = (msg as Record<string, unknown>).usage;
        if (usage && typeof usage === "object" && "cost" in usage) {
          const cost = (usage as Record<string, unknown>).cost;
          if (
            cost &&
            typeof cost === "object" &&
            "total" in cost &&
            typeof (cost as Record<string, unknown>).total === "number"
          ) {
            entries.push({
              cost: (cost as { total: number }).total,
              model:
                ((msg as Record<string, unknown>).model as string) ??
                "unknown",
              date: path.basename(filePath).slice(0, 10),
            });
          }
        }
      }
    }
  }
  return entries;
}

async function findJsonlFiles(
  dir: string,
): Promise<string[]> {
  const files: string[] = [];

  try {
    await fs.readdir(dir, { withFileTypes: true });
  } catch {
    return files;
  }

  const walk = async (d: string) => {
    let entries: (import("node:fs").Dirent)[];
    try {
      entries = await fs.readdir(d, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const full = path.join(d, entry.name);
      if (entry.isDirectory()) {
        await walk(full);
      } else if (entry.name.endsWith(".jsonl")) {
        files.push(full);
      }
    }
  };

  await walk(dir);
  return files;
}

const dateCutoff = (days: number): string => {
  const d = new Date();
  d.setDate(d.getDate() - days);
  return d.toISOString().slice(0, 10);
};

export default function (pi: ExtensionAPI) {
  pi.registerCommand("cost", {
    description:
      "Show API cost summary (default: 7 days). Usage: /cost [days]",
    handler: async (args, ctx) => {
      const days = args?.trim() ? parseInt(args.trim(), 10) : 7;
      if (isNaN(days) || days < 1) {
        ctx.ui.notify("Usage: /cost [days]", "error");
        return;
      }

      const cutoff = dateCutoff(days);
      const sessionsDir = path.join(getAgentDir(), "sessions");

      const files = await findJsonlFiles(sessionsDir);

      let totalCost = 0;
      let sessionCount = 0;
      const byDate: Record<string, number> = {};
      const byModel: Record<string, number> = {};

      for (const filePath of files) {
        const basename = path.basename(filePath);
        const datePart = basename.slice(0, 10);
        if (datePart < cutoff) continue;

        const entries = await extractCosts(filePath);
        if (entries.length === 0) continue;

        sessionCount++;
        for (const e of entries) {
          totalCost += e.cost;
          byDate[e.date] = (byDate[e.date] ?? 0) + e.cost;
          byModel[e.model] = (byModel[e.model] ?? 0) + e.cost;
        }
      }

      const lines: string[] = [];
      lines.push(
        `Total: $${totalCost.toFixed(2)}  (${sessionCount} sessions, last ${days} days)`,
      );

      const dates = Object.keys(byDate).sort();
      if (dates.length > 0) {
        lines.push("");
        lines.push("By date:");
        for (const d of dates) {
          const bar = "\u2588".repeat(
            Math.max(1, Math.round((byDate[d] / totalCost) * 30)),
          );
          lines.push(
            `  ${d}  $${byDate[d].toFixed(2)}`.padEnd(30) + "  " + bar,
          );
        }
      }

      const models = Object.entries(byModel).sort((a, b) => b[1] - a[1]);
      if (models.length > 0) {
        lines.push("");
        lines.push("By model:");
        for (const [name, cost] of models) {
          lines.push(`  ${name.padEnd(30)} $${cost.toFixed(2)}`);
        }
      }

      ctx.ui.notify(lines.join("\n"), "info");
    },
  });
}
