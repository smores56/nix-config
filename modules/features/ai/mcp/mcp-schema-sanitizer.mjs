#!/usr/bin/env node
import { spawn } from "node:child_process";
import readline from "node:readline";

const [, , ...command] = process.argv;

if (command.length === 0) {
  console.error("usage: mcp-schema-sanitizer.mjs <command> [args...]");
  process.exit(64);
}

const child = spawn(command[0], command.slice(1), {
  stdio: ["pipe", "pipe", "pipe"],
});

process.stdin.pipe(child.stdin);
child.stderr.pipe(process.stderr);

const sanitizeSchema = (schema) => {
  if (!schema || typeof schema !== "object" || Array.isArray(schema)) {
    return;
  }

  if (Array.isArray(schema.required) && schema.required.length === 0) {
    delete schema.required;
  }

  for (const value of Object.values(schema)) {
    if (Array.isArray(value)) {
      for (const item of value) {
        sanitizeSchema(item);
      }
    } else {
      sanitizeSchema(value);
    }
  }
};

const sanitizeMessage = (message) => {
  const tools = message?.result?.tools;
  if (!Array.isArray(tools)) {
    return message;
  }

  for (const tool of tools) {
    sanitizeSchema(tool.inputSchema);
  }

  return message;
};

const lines = readline.createInterface({ input: child.stdout });

lines.on("line", (line) => {
  try {
    const message = JSON.parse(line);
    process.stdout.write(`${JSON.stringify(sanitizeMessage(message))}\n`);
  } catch {
    process.stdout.write(`${line}\n`);
  }
});

child.on("exit", (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
    return;
  }

  process.exit(code ?? 1);
});
