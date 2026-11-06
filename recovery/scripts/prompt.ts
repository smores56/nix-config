// Terminal prompts for the operator scripts. One raw-mode reader for both
// hidden and visible input: mixing it with Deno.stdin.readable would lock the
// stream for the rest of the process.

import { type DataKeysBlob, decryptBlob } from "../src/blob.ts";

async function readRaw(label: string, echo: boolean): Promise<string> {
  if (!Deno.stdin.isTerminal()) throw new Error("run this in a terminal");
  await Deno.stderr.write(new TextEncoder().encode(label));
  const bytes: number[] = [];
  const buffer = new Uint8Array(1);
  Deno.stdin.setRaw(true);
  try {
    while (true) {
      const read = await Deno.stdin.read(buffer);
      if (read === null) break;
      const byte = buffer[0];
      if (byte === 13 || byte === 10) break;
      if (byte === 3) {
        Deno.stdin.setRaw(false);
        await Deno.stderr.write(new TextEncoder().encode("\n"));
        Deno.exit(130);
      }
      if (byte === 127 || byte === 8) {
        if (bytes.length > 0) {
          bytes.pop();
          if (echo) await Deno.stderr.write(new TextEncoder().encode("\b \b"));
        }
        continue;
      }
      if (byte >= 32) {
        bytes.push(byte);
        if (echo) await Deno.stderr.write(new Uint8Array([byte]));
      }
    }
  } finally {
    Deno.stdin.setRaw(false);
  }
  await Deno.stderr.write(new TextEncoder().encode("\n"));
  return new TextDecoder().decode(new Uint8Array(bytes));
}

export function promptHidden(label: string): Promise<string> {
  return readRaw(label, false);
}

export function promptVisible(label: string): Promise<string> {
  return readRaw(label, true);
}

export async function promptNewPassword(label: string): Promise<string> {
  const first = await promptHidden(label);
  if (!first) throw new Error("the password is empty");
  const second = await promptHidden("Repeat password: ");
  if (first !== second) throw new Error("the passwords do not match");
  return first;
}

/** Confirms the typed password opens the deployed blob, when the blob exists. */
export async function verifyBlobPassword(path: string, password: string): Promise<boolean | null> {
  let text: string;
  try {
    text = await Deno.readTextFile(path);
  } catch {
    return null;
  }
  const envelope = JSON.parse(text) as DataKeysBlob;
  try {
    await decryptBlob(envelope, password);
    return true;
  } catch {
    return false;
  }
}
