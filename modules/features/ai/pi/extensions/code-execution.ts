import { createRequire } from "node:module";
import { homedir } from "node:os";
import { join } from "node:path";
import { Type } from "typebox";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFile, writeFile } from "node:fs/promises";
import { exec } from "node:child_process";
import { promisify } from "node:util";

// @pydantic/monty is a NAPI native addon — jiti's virtual modules can't bundle it.
// Resolve dynamically from pi's node_modules where bun add installed it.
const piRequire = createRequire(join(homedir(), ".local", "share", "pi-cli", "package.json"));
const { Monty, runMontyAsync } = piRequire("@pydantic/monty");

const execAsync = promisify(exec);

const params = Type.Object({
  code: Type.String({
    description:
      "Python code to execute. Tools (call directly, NO await): read(path='file'), grep(pattern='...', [path='...']), bash(command='...'), write(path='...', content='...'), ls([dir='.']). Calls resolve sequentially at the call site. Intermediate results stay in sandbox, not context.",
  }),
  timeout: Type.Optional(
    Type.Number({ default: 30, description: "Timeout in seconds (max 300)" }),
  ),
});

// Monty calls external functions as fn(...args, kwargs).
// kwargs is always the last arg when present.
function kw(args: unknown[]): Record<string, unknown> {
  const last = args.at(-1);
  if (typeof last === "object" && last !== null && !Array.isArray(last))
    return last as Record<string, unknown>;
  return {};
}

const BRIDGE: Record<string, (...args: unknown[]) => Promise<string>> = {
  async read(...args) {
    const k = kw(args);
    const p = (k.path ?? args[0] ?? "").toString();
    if (!p) return "Error: path required";
    try {
      return await readFile(p, "utf-8");
    } catch (e: unknown) {
      return `Error: ${(e as Error).message}`;
    }
  },
  async bash(...args) {
    const k = kw(args);
    const cmd = (k.command ?? args[0] ?? "").toString();
    if (!cmd) return "Error: command required";
    try {
      const { stdout, stderr } = await execAsync(cmd, {
        timeout: 15_000,
        maxBuffer: 16 * 1024 * 1024,
      });
      return stdout + (stderr ? `\nstderr:\n${stderr}` : "");
    } catch (e: unknown) {
      return `Error: ${(e as Error).message}`;
    }
  },
  async grep(...args) {
    const k = kw(args);
    const pattern = (k.pattern ?? args[0] ?? "").toString();
    const path = (k.path ?? args[1] ?? "").toString();
    if (!pattern) return "Error: pattern required";
    const target = path ? `"${path.replace(/"/g, '\\"')}"` : ".";
    try {
      const { stdout } = await execAsync(`grep -n -- "${pattern}" ${target}`, {
        timeout: 15_000,
      });
      return stdout || "(no matches)";
    } catch (e: unknown) {
      const err = e as NodeJS.ErrnoException;
      if (err.code === "1") return "(no matches)";
      return `Error: ${err.message}`;
    }
  },
  async write(...args) {
    const k = kw(args);
    const p = (k.path ?? "").toString();
    const c = (k.content ?? "").toString();
    if (!p) return "Error: path required";
    try {
      await writeFile(p, c);
      return `wrote ${p}`;
    } catch (e: unknown) {
      return `Error: ${(e as Error).message}`;
    }
  },
  async ls(...args) {
    const k = kw(args);
    const dir = (k.dir ?? args[0] ?? ".").toString();
    try {
      const { stdout } = await execAsync(`ls -la "${dir}"`, { timeout: 10_000 });
      return stdout;
    } catch (e: unknown) {
      return `Error: ${(e as Error).message}`;
    }
  },
};

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "code_execution",
    label: "Python",
    description:
      "Execute Python code in a sandboxed interpreter (Monty). Tools (call directly, NO await/async): read(path='...'), grep(pattern='...', [path='...']), bash(command='...'), write(path='...', content='...'), ls([dir='.']). Calls resolve sequentially. Intermediate tool results stay inside the sandbox, not in LLM context.",
    promptSnippet:
      "Python code execution sandbox — chain tool calls, filter/transform data, batch parallel operations without polluting context.",
    promptGuidelines: [
      "Use code_execution to chain dependent tool calls: filter read results, transform data, loop over many files. Keeps intermediate data out of context.",
      "Call bridge tools directly - NO await, NO asyncio. They return strings synchronously at the call site.",
      "All bridge tools return strings, not objects. Parse output yourself.",
      "Available modules: re, sys, os, json. No other imports, no filesystem/network access outside bridge tools.",
      "Avoid calling a tool when no transformation of its output is performed — let the agent call the tool directly.",
      "NOT a thinking scratchpad. Reason in your text, not in the code block.",
    ],
    parameters: params,
    async execute(_id, params, _signal, _onUpdate, _ctx) {
      // Monty's start/resume loop awaits external functions implicitly:
      // explicit `await` raises an internal error ("Invalid exception type:
      // 'MontyRuntimeError'"), and asyncio doesn't exist. Models habitually
      // write await/asyncio.gather anyway - rewrite to the supported forms.
      const userCode = params.code
        .replace(/\bawait\s+/g, "")
        .replace(/^\s*import asyncio\s*$/gm, "")
        .replace(/\basyncio\.gather\b/g, "_gather");
      const code = `import re\nimport sys\nimport os\nimport json\n\ndef _gather(*args):\n    return list(args)\n\n${userCode}`;
      const timeout = Math.min(params.timeout ?? 30, 300);

      const stdout: string[] = [];
      const m = new Monty(code);

      try {
        const output = await runMontyAsync(m, {
          externalFunctions: BRIDGE,
          printCallback: (_s, t) => {
            stdout.push(t);
          },
          limits: {
            maxExecutionTimeMs: timeout * 1000,
            maxMemoryBytes: 128 * 1024 * 1024,
          },
        });

        const parts: string[] = [];
        const joined = stdout.join("").trimEnd();
        if (joined) parts.push(joined);
        const val = String(output);
        if (val && val !== "None" && val !== "null" && val !== "undefined") parts.push(val);
        const result = parts.length > 0 ? parts.join("\n") : "(no output)";

        return { content: [{ type: "text" as const, text: result }], details: {} };
      } catch (e: unknown) {
        const err = e as Error;
        return {
          content: [{ type: "text" as const, text: `Monty error: ${err.message}` }],
          details: {},
        };
      }
    },
  });
}
