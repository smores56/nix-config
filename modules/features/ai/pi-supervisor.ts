import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { type ChildProcess, execFile, spawn } from "node:child_process";
import { resolve } from "node:path";
import { homedir } from "node:os";
import { createWriteStream, type WriteStream } from "node:fs";
import { mkdir, readdir, readFile, unlink, writeFile } from "node:fs/promises";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

type JsonSchema = Record<string, unknown> & { optional?: true };

const Type = {
  Object: (properties: Record<string, JsonSchema>) => ({
    type: "object",
    properties: Object.fromEntries(
      Object.entries(properties).map(([name, schema]) => {
        const { optional: _optional, ...rest } = schema;
        return [name, rest];
      }),
    ),
    required: Object.entries(properties)
      .filter(([, schema]) => !schema.optional)
      .map(([name]) => name),
  }),
  String: (options: Record<string, unknown> = {}) => ({
    type: "string",
    ...options,
  }),
  Number: (options: Record<string, unknown> = {}) => ({
    type: "number",
    ...options,
  }),
  Optional: (schema: JsonSchema) => ({ ...schema, optional: true }),
};

type SessionStatus = "running" | "idle" | "error" | "dead";

interface ChildEntry {
  name: string;
  task: string;
  status: SessionStatus;
  output: string[];
  createdAt: number;
  lastActivity: number;
  sessionDir: string;
}

interface RpcChild {
  entry: ChildEntry;
  process: ChildProcess | null;
  buffer: string;
  responseHandlers: Map<
    string,
    {
      resolve: (msg: RpcResponse) => void;
      reject: (err: Error) => void;
      timer: ReturnType<typeof setTimeout>;
    }
  >;
  nextId: number;
}

interface RpcResponse {
  type: "response";
  command: string;
  success: boolean;
  id?: string;
  error?: string;
  data?: unknown;
}

interface RpcEvent {
  type: string;
  assistantMessageEvent?: { type: string; delta?: string };
  toolName?: string;
  isError?: boolean;
  [key: string]: unknown;
}

interface Registry {
  children: Record<
    string,
    { sessionDir: string; task: string; status: string; createdAt: number }
  >;
  supervisorSession?: string;
}

interface ToolResult {
  content: Array<{ type: string; text: string }>;
  details?: Record<string, unknown>;
}

const children = new Map<string, RpcChild>();
const sessionsDir = resolve(homedir(), ".pi/agent/sessions/supervisor");
const registryPath = resolve(sessionsDir, "registry.json");
const logPath = resolve(sessionsDir, "supervisor.log");
let latestCtx: ExtensionContext | null = null;
let logStream: WriteStream | null = null;

const MAX_OUTPUT_LINES = 200;
const OUTPUT_TRIM_INTERVAL = 50;

function log(level: "info" | "warn" | "error", msg: string): void {
  if (!logStream) {
    logStream = createWriteStream(logPath, { flags: "a" });
    logStream.on("error", () => {});
  }
  logStream.write(`[${new Date().toISOString()}] [${level}] ${msg}\n`);
}

function errorMsg(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

const STATUS_ICONS: Record<SessionStatus, string> = {
  running: "●",
  idle: "◌",
  error: "✗",
  dead: "…",
};

function statusIcon(status: SessionStatus): string {
  return STATUS_ICONS[status];
}

function getChildOrError(name: string): RpcChild | ToolResult {
  const child = children.get(name);
  if (!child) {
    return {
      content: [{ type: "text", text: `No session named "${name}".` }],
      details: { error: "not_found" },
    };
  }
  return child;
}

function isToolResult(v: RpcChild | ToolResult): v is ToolResult {
  return "content" in v;
}

// --- Registry persistence (debounced) ---

let registryDirty = false;
let registryTimer: ReturnType<typeof setTimeout> | null = null;

async function loadRegistry(): Promise<Registry> {
  try {
    return JSON.parse(await readFile(registryPath, "utf-8"));
  } catch {
    return { children: {} };
  }
}

function markRegistryDirty(): void {
  registryDirty = true;
  if (registryTimer) return;
  registryTimer = setTimeout(() => {
    registryTimer = null;
    if (registryDirty) flushRegistry();
  }, 1000);
}

async function flushRegistry(): Promise<void> {
  registryDirty = false;
  const reg: Registry = { children: {} };
  for (const [, child] of children) {
    reg.children[child.entry.name] = {
      sessionDir: child.entry.sessionDir,
      task: child.entry.task,
      status: child.entry.status,
      createdAt: child.entry.createdAt,
    };
  }
  if (latestCtx) {
    reg.supervisorSession = latestCtx.sessionManager.getSessionFile?.() ??
      undefined;
  }
  await writeFile(registryPath, JSON.stringify(reg, null, 2));
}

// --- Widget (debounced) ---

let widgetTimer: ReturnType<typeof setTimeout> | null = null;

function scheduleWidgetUpdate(): void {
  if (widgetTimer) return;
  widgetTimer = setTimeout(() => {
    widgetTimer = null;
    renderWidget();
  }, 200);
}

function renderWidget(): void {
  if (!latestCtx) return;
  if (children.size === 0) {
    latestCtx.ui.setWidget("supervisor-sessions", undefined);
    return;
  }

  const lines = ["─── Sessions ───"];
  for (const child of children.values()) {
    const age = formatAge(Date.now() - child.entry.createdAt);
    lines.push(
      ` ${statusIcon(child.entry.status)} ${child.entry.name}  ${age}  ${
        child.entry.task.slice(0, 50)
      }`,
    );
  }

  latestCtx.ui.setWidget("supervisor-sessions", lines, {
    placement: "belowEditor",
  });
}

function formatAge(ms: number): string {
  const secs = Math.floor(ms / 1000);
  if (secs < 60) return `${secs}s`;
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${mins}m`;
  const hrs = Math.floor(mins / 60);
  return `${hrs}h${mins % 60}m`;
}

// --- RPC child management ---

function drainResponseHandlers(child: RpcChild, reason: string): void {
  for (const [id, handler] of child.responseHandlers) {
    clearTimeout(handler.timer);
    handler.reject(
      new Error(`${child.entry.name}: ${reason} (pending: ${id})`),
    );
  }
  child.responseHandlers.clear();
}

function spawnRpcChild(
  name: string,
  task: string,
  cwd: string,
  sessionDir: string,
): RpcChild {
  const model = process.env.OPENAI_MODEL ?? "qwen3.6-27b";
  const baseUrl = process.env.OPENAI_HOST ?? "http://campfire:8080";
  const args = [
    "--mode",
    "rpc",
    "--provider",
    "campfire",
    "--model",
    model,
    "--session-dir",
    sessionDir,
    "--cwd",
    cwd,
  ];
  log("info", `spawn ${name}: pi ${args.join(" ")} (baseUrl=${baseUrl})`);

  const proc = spawn("pi", args, {
    stdio: ["pipe", "pipe", "pipe"],
    env: { ...process.env, PI_SUPERVISOR_CHILD: "1" },
  });

  const child: RpcChild = {
    entry: {
      name,
      task,
      status: "running",
      output: [],
      createdAt: Date.now(),
      lastActivity: Date.now(),
      sessionDir,
    },
    process: proc,
    buffer: "",
    responseHandlers: new Map(),
    nextId: 1,
  };

  let appendsSinceTrim = 0;

  proc.stdout!.on("data", (chunk: Buffer) => {
    child.buffer += chunk.toString();
    const lines = child.buffer.split("\n");
    child.buffer = lines.pop()!;
    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        const msg = JSON.parse(line);
        if (msg.type === "response" && msg.id) {
          const handler = child.responseHandlers.get(msg.id);
          if (handler) {
            clearTimeout(handler.timer);
            child.responseHandlers.delete(msg.id);
            handler.resolve(msg as RpcResponse);
          }
        } else {
          handleChildEvent(child, msg as RpcEvent);
        }
      } catch {
        log("warn", `${name} non-JSON stdout: ${line.slice(0, 200)}`);
      }
    }
  });

  proc.stderr!.on("data", (chunk: Buffer) => {
    const text = chunk.toString().trim();
    if (text) log("warn", `${name} stderr: ${text}`);
  });

  proc.on("error", (err) => {
    log("error", `${name} process error: ${err.message}`);
    drainResponseHandlers(child, "process error");
    child.entry.status = "error";
    child.entry.lastActivity = Date.now();
    scheduleWidgetUpdate();
  });

  proc.on("exit", (code, signal) => {
    log("info", `${name} exited code=${code} signal=${signal}`);
    drainResponseHandlers(child, `exited code=${code}`);
    child.entry.status = code === 0 ? "idle" : "error";
    child.entry.lastActivity = Date.now();
    scheduleWidgetUpdate();
    markRegistryDirty();
  });

  function handleChildEvent(_child: RpcChild, event: RpcEvent): void {
    _child.entry.lastActivity = Date.now();

    switch (event.type) {
      case "agent_start":
        _child.entry.status = "running";
        break;
      case "agent_end":
        _child.entry.status = "idle";
        break;
      case "message_update":
        if (
          event.assistantMessageEvent?.type === "text_delta" &&
          event.assistantMessageEvent.delta
        ) {
          appendOutput(_child, event.assistantMessageEvent.delta);
        }
        break;
      case "tool_execution_start":
        appendOutput(_child, `\n[tool: ${event.toolName}]\n`);
        break;
      case "tool_execution_end":
        if (event.isError) appendOutput(_child, "[tool error]\n");
        break;
    }

    scheduleWidgetUpdate();
  }

  function appendOutput(_child: RpcChild, text: string): void {
    const lastIdx = _child.entry.output.length - 1;
    if (lastIdx >= 0 && !_child.entry.output[lastIdx].endsWith("\n")) {
      _child.entry.output[lastIdx] += text;
    } else {
      _child.entry.output.push(text);
    }
    appendsSinceTrim++;
    if (
      appendsSinceTrim >= OUTPUT_TRIM_INTERVAL &&
      _child.entry.output.length > MAX_OUTPUT_LINES
    ) {
      _child.entry.output = _child.entry.output.slice(-MAX_OUTPUT_LINES);
      appendsSinceTrim = 0;
    }
  }

  return child;
}

function sendRpc(
  child: RpcChild,
  command: string,
  params: Record<string, unknown> = {},
): Promise<RpcResponse> {
  if (!child.process) {
    return Promise.reject(new Error(`${child.entry.name}: no process`));
  }

  const id = `req-${child.nextId++}`;
  log("info", `${child.entry.name} rpc send: ${command} (${id})`);

  return new Promise((res, rej) => {
    const timer = setTimeout(() => {
      child.responseHandlers.delete(id);
      const err = new Error(
        `RPC timeout for ${command} on ${child.entry.name}`,
      );
      log("error", err.message);
      rej(err);
    }, 300_000);

    child.responseHandlers.set(id, { resolve: res, reject: rej, timer });

    const line = JSON.stringify({ command, ...params, id }) + "\n";
    child.process!.stdin!.write(line);
  });
}

// --- Helpers ---

async function findSessionFile(dir: string): Promise<string | null> {
  try {
    const files = await readdir(dir);
    const jsonl = files.find((f) => f.endsWith(".jsonl"));
    return jsonl ? resolve(dir, jsonl) : null;
  } catch {
    return null;
  }
}

// --- Extension entry point ---

export default async function supervisorExtension(pi: ExtensionAPI) {
  const baseUrl = process.env.OPENAI_HOST ?? "http://campfire:8080";

  pi.registerProvider("campfire", {
    name: "campfire llama.cpp",
    baseUrl: `${baseUrl}/v1`,
    apiKey: "PI_CAMPFIRE_API_KEY",
    api: "openai-completions",
    compat: {
      supportsStore: false,
      supportsDeveloperRole: false,
      supportsReasoningEffort: false,
      supportsUsageInStreaming: true,
      maxTokensField: "max_tokens",
    },
    models: [
      {
        id: "qwen3.6-27b",
        name: "Qwen 3.6 27B",
        reasoning: false,
        input: ["text"],
        contextWindow: 131072,
        maxTokens: 8192,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      },
    ],
  });

  if (process.env.PI_SUPERVISOR_CHILD === "1") {
    log("info", "loaded as child — skipping supervisor registration");
    return;
  }

  await mkdir(sessionsDir, { recursive: true });
  log("info", "supervisor extension starting");

  const registry = await loadRegistry();
  const restoredCount = Object.keys(registry.children).length;
  if (restoredCount > 0) {
    log("info", `restoring ${restoredCount} session(s) from registry`);
  }

  for (const [name, info] of Object.entries(registry.children)) {
    children.set(name, {
      entry: {
        name,
        task: info.task,
        status: "idle",
        output: [],
        createdAt: info.createdAt,
        lastActivity: Date.now(),
        sessionDir: info.sessionDir,
      },
      process: null,
      buffer: "",
      responseHandlers: new Map(),
      nextId: 1,
    });
  }

  pi.on("session_start", async (_event, ctx) => {
    latestCtx = ctx;
    renderWidget();
  });

  pi.on("session_shutdown", async () => {
    log("info", `shutting down — killing ${children.size} child process(es)`);
    for (const child of children.values()) {
      if (child.process?.pid) child.process.kill("SIGTERM");
    }
    if (registryTimer) clearTimeout(registryTimer);
    await flushRegistry();
    logStream?.end();
  });

  // --- Tools ---

  pi.registerTool({
    name: "spawn_session",
    label: "Spawn Session",
    description:
      "Create a new background agent session. The child session runs autonomously with full coding tools (read, write, edit, bash). Use this to delegate tasks that can run independently.",
    parameters: Type.Object({
      name: Type.String({
        description: "Short identifier for the session (kebab-case)",
      }),
      task: Type.String({
        description: "The task prompt to send to the child agent",
      }),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      if (children.has(params.name)) {
        return {
          content: [{
            type: "text",
            text:
              `Session "${params.name}" already exists. Use a different name or kill it first.`,
          }],
          details: { error: "exists" },
        };
      }

      const sessionDir = resolve(sessionsDir, params.name);
      await mkdir(sessionDir, { recursive: true });

      const child = spawnRpcChild(
        params.name,
        params.task,
        ctx.cwd,
        sessionDir,
      );
      children.set(params.name, child);
      scheduleWidgetUpdate();
      markRegistryDirty();

      sendRpc(child, "prompt", { text: params.task }).catch((err) => {
        log("error", `${params.name} initial prompt failed: ${errorMsg(err)}`);
        child.entry.status = "error";
        scheduleWidgetUpdate();
      });

      return {
        content: [{
          type: "text",
          text: `Session "${params.name}" spawned. Task: ${params.task}`,
        }],
        details: { name: params.name },
      };
    },
  });

  pi.registerTool({
    name: "list_sessions",
    label: "List Sessions",
    description: "List all managed child sessions and their current status.",
    parameters: Type.Object({}),
    async execute() {
      if (children.size === 0) {
        return {
          content: [{ type: "text", text: "No active sessions." }],
          details: { count: 0 },
        };
      }

      const lines = Array.from(children.values()).map((c) => {
        const age = formatAge(Date.now() - c.entry.createdAt);
        const outputTail = c.entry.output.slice(-3).join("").trim();
        return `[${c.entry.status}] ${c.entry.name} (${age}) — ${c.entry.task}\n  Last output: ${
          outputTail || "(none)"
        }`;
      });

      return {
        content: [{ type: "text", text: lines.join("\n\n") }],
        details: {
          count: children.size,
          sessions: Array.from(children.keys()),
        },
      };
    },
  });

  pi.registerTool({
    name: "check_session",
    label: "Check Session",
    description: "Get the recent output from a child session.",
    parameters: Type.Object({
      name: Type.String({ description: "Session name" }),
      lines: Type.Optional(
        Type.Number({
          description: "Number of output lines to return (default 30)",
        }),
      ),
    }),
    async execute(_toolCallId, params) {
      const result = getChildOrError(params.name);
      if (isToolResult(result)) return result;

      const n = params.lines ?? 30;
      const tail = result.entry.output.slice(-n).join("");

      return {
        content: [{
          type: "text",
          text:
            `[${result.entry.status}] ${result.entry.name}\nTask: ${result.entry.task}\n\n${
              tail || "(no output yet)"
            }`,
        }],
        details: { status: result.entry.status, name: result.entry.name },
      };
    },
  });

  pi.registerTool({
    name: "message_session",
    label: "Message Session",
    description:
      "Send a follow-up message to an existing child session. If the child's process has exited, a new one is spawned on the same session history.",
    parameters: Type.Object({
      name: Type.String({ description: "Session name" }),
      message: Type.String({ description: "Message to send" }),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const result = getChildOrError(params.name);
      if (isToolResult(result)) return result;

      if (!result.process?.pid || result.process.exitCode !== null) {
        const respawned = spawnRpcChild(
          result.entry.name,
          result.entry.task,
          ctx.cwd,
          result.entry.sessionDir,
        );
        result.process = respawned.process;
        result.buffer = "";
        result.responseHandlers = new Map();
        result.nextId = 1;
      }

      result.entry.status = "running";
      scheduleWidgetUpdate();

      sendRpc(result, "prompt", { text: params.message }).catch(() => {
        result.entry.status = "error";
        scheduleWidgetUpdate();
      });

      return {
        content: [{ type: "text", text: `Message sent to "${params.name}".` }],
        details: { name: params.name },
      };
    },
  });

  pi.registerTool({
    name: "kill_session",
    label: "Kill Session",
    description:
      "Terminate a child session. The session history is preserved on disk.",
    parameters: Type.Object({
      name: Type.String({ description: "Session name" }),
    }),
    async execute(_toolCallId, params) {
      const result = getChildOrError(params.name);
      if (isToolResult(result)) return result;

      log(
        "info",
        `killing session ${params.name} (pid=${result.process?.pid ?? "none"})`,
      );
      if (result.process?.pid) result.process.kill("SIGTERM");
      children.delete(params.name);
      scheduleWidgetUpdate();
      markRegistryDirty();

      return {
        content: [{
          type: "text",
          text:
            `Session "${params.name}" killed. Session history preserved at ${result.entry.sessionDir}`,
        }],
        details: { name: params.name },
      };
    },
  });

  // --- Commands ---

  pi.registerCommand("health", {
    description:
      "Check supervisor prerequisites: Pi CLI, campfire connectivity, RPC mode",
    handler: async (_args, ctx) => {
      const checks: string[] = [];

      try {
        const { stdout } = await execFileAsync("pi", ["--version"]);
        checks.push(`[ok] pi CLI: ${stdout.trim()}`);
      } catch (err: unknown) {
        checks.push(`[FAIL] pi CLI not found: ${errorMsg(err)}`);
      }

      try {
        const rpcOk = await new Promise<string>((res) => {
          const p = spawn("pi", ["--mode", "rpc", "--no-session"], {
            stdio: ["pipe", "pipe", "pipe"],
            env: { ...process.env, PI_SUPERVISOR_CHILD: "1" },
          });
          const timer = setTimeout(() => {
            p.kill();
            res("timeout (5s) — may still be ok if Pi is loading extensions");
          }, 5000);
          p.stdout!.once("data", () => {
            clearTimeout(timer);
            p.kill();
            res("ok");
          });
          p.stderr!.once("data", (d: Buffer) => {
            clearTimeout(timer);
            p.kill();
            res(`stderr: ${d.toString().trim().slice(0, 200)}`);
          });
          p.on("error", (e) => {
            clearTimeout(timer);
            res(`spawn error: ${e.message}`);
          });
        });
        checks.push(
          `[${rpcOk === "ok" ? "ok" : "WARN"}] pi RPC mode: ${rpcOk}`,
        );
      } catch (err: unknown) {
        checks.push(`[FAIL] pi RPC mode: ${errorMsg(err)}`);
      }

      try {
        const resp = await fetch(`${baseUrl}/v1/models`, {
          signal: AbortSignal.timeout(5000),
        });
        if (resp.ok) {
          const body = await resp.json() as { data?: Array<{ id: string }> };
          const models = body.data?.map((m) => m.id).join(", ") ?? "unknown";
          checks.push(`[ok] ${baseUrl} reachable — models: ${models}`);
        } else {
          checks.push(
            `[FAIL] ${baseUrl} responded ${resp.status} ${resp.statusText}`,
          );
        }
      } catch (err: unknown) {
        checks.push(`[FAIL] ${baseUrl} unreachable: ${errorMsg(err)}`);
      }

      const model = process.env.OPENAI_MODEL;
      checks.push(
        model
          ? `[ok] OPENAI_MODEL=${model}`
          : `[WARN] OPENAI_MODEL not set, defaulting to qwen3.6-27b`,
      );

      try {
        const testFile = resolve(sessionsDir, ".health-check");
        await writeFile(testFile, "ok");
        await unlink(testFile);
        checks.push(`[ok] sessions dir writable: ${sessionsDir}`);
      } catch (err: unknown) {
        checks.push(`[FAIL] sessions dir not writable: ${errorMsg(err)}`);
      }

      checks.push(`[info] ${children.size} session(s) in registry`);
      checks.push(`[info] log file: ${logPath}`);

      const report = checks.join("\n");
      log("info", `health check:\n${report}`);
      ctx.ui.notify(report, "info");
    },
  });

  pi.registerCommand("enter", {
    description: "Enter a child session for interactive use",
    getArgumentCompletions: (prefix) => {
      const names = Array.from(children.keys()).filter((n) =>
        n.startsWith(prefix)
      );
      return names.length > 0
        ? names.map((n) => ({ value: n, label: n }))
        : null;
    },
    handler: async (args, ctx) => {
      const name = args.trim();
      const child = children.get(name);
      if (!child) {
        ctx.ui.notify(`No session "${name}"`, "error");
        return;
      }

      if (child.process?.pid) child.process.kill("SIGTERM");
      await flushRegistry();

      const sessionPath = await findSessionFile(child.entry.sessionDir);
      if (!sessionPath) {
        ctx.ui.notify(
          `No session file found in ${child.entry.sessionDir}`,
          "error",
        );
        return;
      }

      await ctx.switchSession(sessionPath, {
        withSession: async (newCtx) => {
          newCtx.ui.notify(
            `Entered session "${name}". Use /back to return to supervisor.`,
            "info",
          );
        },
      });
    },
  });

  pi.registerCommand("back", {
    description: "Return to the supervisor session",
    handler: async (_args, ctx) => {
      const reg = await loadRegistry();
      if (!reg.supervisorSession) {
        ctx.ui.notify("No supervisor session to return to.", "error");
        return;
      }

      await ctx.switchSession(reg.supervisorSession, {
        withSession: async (newCtx) => {
          newCtx.ui.notify("Back in supervisor.", "info");
        },
      });
    },
  });

  pi.registerCommand("sessions", {
    description: "Show child session status",
    handler: async (_args, ctx) => {
      if (children.size === 0) {
        ctx.ui.notify("No sessions.", "info");
        return;
      }

      const names = Array.from(children.keys());
      const items = names.map((n) => {
        const c = children.get(n)!;
        return `${statusIcon(c.entry.status)} ${n} [${c.entry.status}] — ${
          c.entry.task.slice(0, 60)
        }`;
      });

      const selected = await ctx.ui.select("Sessions", items);
      if (selected) {
        const idx = items.indexOf(selected);
        if (idx >= 0) {
          const child = children.get(names[idx])!;
          const tail = child.entry.output.slice(-20).join("");
          ctx.ui.notify(
            `${child.entry.name} [${child.entry.status}]\n${
              tail || "(no output)"
            }`,
            "info",
          );
        }
      }
    },
  });
}
