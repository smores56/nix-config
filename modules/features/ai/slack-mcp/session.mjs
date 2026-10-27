import { createHash, createDecipheriv, pbkdf2Sync, timingSafeEqual } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { spawn, spawnSync } from 'node:child_process';
import { Transform } from 'node:stream';
import { finished } from 'node:stream/promises';
import { StringDecoder } from 'node:string_decoder';
import { lstat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { isAbsolute, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { extractLeveldbTokens } from './leveldb.mjs';

export const READ_TOOLS = Object.freeze([
  'conversations_history',
  'conversations_replies',
  'conversations_search_messages',
  'conversations_unreads',
  'channels_list',
  'channels_me',
  'users_search',
  'usergroups_list',
]);

const TOKEN_PATTERN = /^xoxc-[A-Za-z0-9-]{6,}$/;
const COOKIE_PATTERN = /^xoxd-[A-Za-z0-9%._~+\/=:-]+$/;
const TEAM_PATTERN = /^[A-Z0-9]+$/;
const USER_PATTERN = /^[A-Z0-9]+$/;
const SERVER_ARGS = Object.freeze([
  '--transport', 'stdio', '--enabled-tools', READ_TOOLS.join(','),
]);
export const MAX_NDJSON_BYTES = 8 * 1024 * 1024;
const MAX_AUTH_ATTEMPTS = 128;
export const KEYCHAIN_SERVICE = 'maki-slack-mcp';
export const KEYCHAIN_ACCOUNT = 'desktop-session';

export function decryptCookie(encryptedValue, password, host, databaseVersion) {
  if (!Buffer.isBuffer(encryptedValue) || !password || !/^(?:[a-z0-9-]+\.)*slack\.com$/i.test((host ?? '').replace(/^\./, '')) || !Number.isInteger(databaseVersion)) return null;
  if (encryptedValue.length < 16 || encryptedValue.subarray(0, 3).toString() !== 'v10') return null;
  try {
    const key = pbkdf2Sync(password, 'saltysalt', 1003, 16, 'sha1');
    const decipher = createDecipheriv('aes-128-cbc', key, Buffer.alloc(16, 32));
    const plaintext = Buffer.concat([decipher.update(encryptedValue.subarray(3)), decipher.final()]);
    let value = plaintext;
    if (databaseVersion >= 24) {
      if (plaintext.length < 33) return null;
      const hostHash = createHash('sha256').update(host).digest();
      if (!timingSafeEqual(plaintext.subarray(0, hostHash.length), hostHash)) return null;
      value = plaintext.subarray(hostHash.length);
    }
    const decoded = value.toString('utf8');
    return COOKIE_PATTERN.test(decoded) ? decoded : null;
  } catch {
    return null;
  }
}

export function validateCredentials(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || typeof value.xoxc !== 'string' || !TOKEN_PATTERN.test(value.xoxc)
      || typeof value.xoxd !== 'string' || !COOKIE_PATTERN.test(value.xoxd)
      || typeof value.team_id !== 'string' || !TEAM_PATTERN.test(value.team_id)
      || typeof value.user_id !== 'string' || !USER_PATTERN.test(value.user_id)) {
    throw new Error('Invalid Slack MCP credentials');
  }
  return { xoxc: value.xoxc, xoxd: value.xoxd, team_id: value.team_id, user_id: value.user_id };
}

export async function saveCredentials(value, run = spawnSync) {
  const credentials = validateCredentials(value);
  try {
    const encoded = Buffer.from(JSON.stringify(credentials)).toString('hex');
    const input = `add-generic-password -U -a ${KEYCHAIN_ACCOUNT} -s ${KEYCHAIN_SERVICE} -X ${encoded}\n`;
    if (Buffer.byteLength(input) > 4095) throw new Error('Keychain command exceeds safe input limit');
    const result = run('/usr/bin/security', ['-i'], {
      input,
      encoding: 'utf8', timeout: 30000, stdio: ['pipe', 'ignore', 'ignore'],
    });
    if (result.error || result.status !== 0) throw new Error('Keychain write failed');
    const saved = await loadCredentials(run);
    if (Object.keys(credentials).some((key) => saved[key] !== credentials[key])) throw new Error('Keychain verification failed');
  } catch {
    throw new Error('Could not save Slack MCP credentials in macOS Keychain');
  }
}

export async function loadCredentials(run = spawnSync) {
  try {
    const result = run('/usr/bin/security', ['find-generic-password', '-a', KEYCHAIN_ACCOUNT, '-s', KEYCHAIN_SERVICE, '-w'], {
      encoding: 'utf8', timeout: 30000, maxBuffer: 65536, stdio: ['ignore', 'pipe', 'ignore'],
    });
    if (result.error || result.status !== 0) throw new Error('Keychain read failed');
    return validateCredentials(JSON.parse(result.stdout.trim()));
  } catch {
    throw new Error('Slack MCP credentials are unavailable in macOS Keychain; run the auth command again');
  }
}

function validateBackend(backend) {
  if (typeof backend !== 'string' || !isAbsolute(backend) || /[\0\r\n]/.test(backend)) {
    throw new Error('Slack MCP backend must be an absolute executable path');
  }
  return backend;
}

export function serverOptions(credentials, { backend, inherited = process.env } = {}) {
  const command = validateBackend(backend);
  const selected = validateCredentials(credentials);
  const env = Object.fromEntries(['PATH', 'HOME', 'TMPDIR'].flatMap((key) => typeof inherited[key] === 'string' ? [[key, inherited[key]]] : []));
  env.SLACK_MCP_XOXC_TOKEN = selected.xoxc;
  env.SLACK_MCP_XOXD_TOKEN = selected.xoxd;
  env.SLACK_MCP_LOG_LEVEL = 'error';
  return { command, args: [...SERVER_ARGS], env };
}

export function sanitizeSchema(value) {
  if (Array.isArray(value)) return value.map(sanitizeSchema);
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(Object.entries(value)
    .filter(([key, item]) => key !== 'required' || !Array.isArray(item) || item.length > 0)
    .map(([key, item]) => [key, sanitizeSchema(item)]));
}

function redact(value, credentials) {
  if (typeof value === 'string') {
    for (const credential of [credentials.xoxc, credentials.xoxd]) {
      if (credential) value = value.split(credential).join('[redacted Slack credential]');
    }
    return value;
  }
  if (Array.isArray(value)) return value.map((item) => redact(item, credentials));
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(Object.entries(value).map(([key, item]) => [redact(key, credentials), redact(item, credentials)]));
}

export function sanitizeMessage(message, credentials = { xoxc: '', xoxd: '' }) {
  if (Array.isArray(message)) return message.map((item) => sanitizeMessage(item, credentials));
  let result = message;
  if (message && typeof message === 'object' && Array.isArray(message.result?.tools)) {
    result = {
      ...message,
      result: {
        ...message.result,
        tools: message.result.tools
          .filter((tool) => READ_TOOLS.includes(tool.name))
          .map((tool) => ({
            ...tool,
            ...(tool.inputSchema ? { inputSchema: sanitizeSchema(tool.inputSchema) } : {}),
            ...(tool.outputSchema ? { outputSchema: sanitizeSchema(tool.outputSchema) } : {}),
          })),
      },
    };
  }
  return credentials.xoxc || credentials.xoxd ? redact(result, credentials) : result;
}

function createLineTransform(transformLine, onError, maxLineBytes) {
  if (!Number.isSafeInteger(maxLineBytes) || maxLineBytes < 1 || maxLineBytes > MAX_NDJSON_BYTES) {
    throw new Error('Invalid Slack MCP NDJSON byte limit');
  }
  let buffer = '';
  let bytes = 0;
  let decoder = new StringDecoder('utf8');
  const append = (chunk) => {
    if (chunk.length > maxLineBytes - bytes) throw new Error(onError);
    bytes += chunk.length;
    buffer += decoder.write(chunk);
  };
  const emit = (stream) => {
    buffer += decoder.end();
    if (buffer.length) {
      const line = transformLine(buffer);
      if (line) stream.push(`${line}\n`);
    }
    buffer = '';
    bytes = 0;
    decoder = new StringDecoder('utf8');
  };
  return new Transform({
    transform(chunk, encoding, callback) {
      try {
        let offset = 0;
        let end;
        while ((end = chunk.indexOf(10, offset)) !== -1) {
          append(chunk.subarray(offset, end));
          emit(this);
          offset = end + 1;
        }
        append(chunk.subarray(offset));
        callback();
      } catch {
        buffer = '';
        callback(new Error(onError));
      }
    },
    flush(callback) {
      try {
        emit(this);
        callback();
      } catch {
        callback(new Error(onError));
      }
    },
  });
}

export function createMcpFilter(credentials, { maxLineBytes = MAX_NDJSON_BYTES } = {}) {
  return createLineTransform((line) => JSON.stringify(sanitizeMessage(JSON.parse(line), credentials)), 'Invalid Slack MCP server output', maxLineBytes);
}

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function validEnvelope(message) {
  if (!isObject(message) || message.jsonrpc !== '2.0'
      || Object.keys(message).some((key) => !['jsonrpc', 'id', 'method', 'params', 'result', 'error'].includes(key))) return false;
  if (message.method === 'tools/call' && isObject(message.params)
      && (Object.keys(message.params).some((key) => !['name', 'arguments', '_meta'].includes(key))
        || (Object.hasOwn(message.params, 'arguments') && !isObject(message.params.arguments)))) return false;
  const has = (key) => Object.hasOwn(message, key);
  const validId = typeof message.id === 'string' || Number.isSafeInteger(message.id);
  if (has('method')) {
    return typeof message.method === 'string' && message.method.length > 0
      && (!has('id') || validId) && (!has('params') || isObject(message.params))
      && !has('result') && !has('error');
  }
  return has('id') && validId && !has('params') && (has('result') !== has('error'))
    && (!has('error') || (isObject(message.error) && Number.isSafeInteger(message.error.code) && typeof message.error.message === 'string'));
}

export function createMcpRequestFilter(onRejected = () => {}, { maxLineBytes = MAX_NDJSON_BYTES } = {}) {
  return createLineTransform((line) => {
    const message = JSON.parse(line);
    if (!validEnvelope(message)) throw new Error('Invalid Maki MCP request');
    if (message.method === 'tools/call' && !READ_TOOLS.includes(message.params?.name)) {
      if (Object.hasOwn(message, 'id')) onRejected({
        jsonrpc: '2.0',
        id: message.id,
        error: { code: -32000, message: 'Tool blocked by local read-only policy' },
      });
      return '';
    }
    return JSON.stringify(message);
  }, 'Invalid Maki MCP request', maxLineBytes);
}

export async function authTest(credentials, request = fetch) {
  let candidate;
  try {
    candidate = validateCredentials({ ...credentials, team_id: credentials.team_id ?? 'TEMP', user_id: credentials.user_id ?? 'TEMP' });
  } catch {
    return null;
  }
  try {
    const response = await request('https://slack.com/api/auth.test', {
      method: 'GET',
      headers: {
        Authorization: `Bearer ${candidate.xoxc}`,
        Cookie: `d=${candidate.xoxd}`,
      },
      redirect: 'error',
      signal: AbortSignal.timeout(10000),
    });
    const result = await response.json();
    if (response.ok === false || result?.ok !== true || !TEAM_PATTERN.test(result.team_id ?? '') || !USER_PATTERN.test(result.user_id ?? '') || typeof result.team !== 'string') return null;
    return { ok: true, team: result.team, team_id: result.team_id, user_id: result.user_id };
  } catch {
    return null;
  }
}

export async function authorizeTeam(candidates, teamId, requestAuth = authTest, persist = saveCredentials) {
  if (!TEAM_PATTERN.test(teamId ?? '')) throw new Error('Choose a valid Slack workspace ID');
  let attempts = 0;
  for (const xoxc of candidates.tokens) {
    for (const xoxd of candidates.cookies) {
      if (++attempts > MAX_AUTH_ATTEMPTS) break;
      const identity = await requestAuth({ xoxc, xoxd });
      if (identity?.ok === true && identity.team_id === teamId) {
        const credentials = { xoxc, xoxd, team_id: identity.team_id, user_id: identity.user_id };
        await persist(credentials);
        return identity;
      }
    }
    if (attempts > MAX_AUTH_ATTEMPTS) break;
  }
  return null;
}

function slackSafeStoragePassword() {
  const result = spawnSync('/usr/bin/security', ['find-generic-password', '-s', 'Slack Safe Storage', '-w'], {
    encoding: 'utf8', timeout: 10000, maxBuffer: 4096, stdio: ['ignore', 'pipe', 'ignore'],
  });
  if (result.error || result.status !== 0 || !result.stdout.trim()) throw new Error('Could not read Slack Safe Storage from Keychain');
  return result.stdout.trim();
}

function isSlackHost(host) {
  return typeof host === 'string' && (host.toLowerCase() === 'slack.com' || host.toLowerCase().endsWith('.slack.com'));
}

async function cookieValues(path, passwordReader) {
  let database;
  try {
    database = new DatabaseSync(path, { readOnly: true });
    const versionRow = database.prepare("SELECT value FROM meta WHERE key = 'version'").get();
    const version = Number(versionRow?.value);
    if (!Number.isInteger(version)) return [];
    const rows = database.prepare("SELECT host_key, value, encrypted_value FROM cookies WHERE name = 'd'").all();
    const values = [];
    const encryptedRows = [];
    for (const row of rows) {
      if (!isSlackHost(row.host_key)) continue;
      if (ArrayBuffer.isView(row.encrypted_value) && row.encrypted_value.byteLength > 0) encryptedRows.push({ ...row, encrypted_value: Buffer.from(row.encrypted_value) });
      else if (typeof row.value === 'string' && COOKIE_PATTERN.test(row.value)) values.push(row.value);
    }
    if (encryptedRows.length > 0) {
      let password;
      try {
        password = await passwordReader();
      } catch {
        return [...new Set(values)];
      }
      for (const row of encryptedRows) {
        const value = decryptCookie(row.encrypted_value, password, row.host_key, version);
        if (value) values.push(value);
      }
    }
    return [...new Set(values)];
  } catch {
    return [];
  } finally {
    database?.close();
  }
}

export async function extractDesktop(root = join(homedir(), 'Library', 'Application Support', 'Slack'), passwordReader = slackSafeStoragePassword) {
  const cookies = new Set();
  let passwordPromise;
  const getPassword = () => passwordPromise ??= Promise.resolve().then(passwordReader);
  for (const path of [join(root, 'Cookies'), join(root, 'Network', 'Cookies')]) {
    try {
      const metadata = await lstat(path);
      if (!metadata.isFile() || metadata.isSymbolicLink()) continue;
      for (const cookie of await cookieValues(path, getPassword)) cookies.add(cookie);
    } catch {
      continue;
    }
  }

  return { tokens: await extractLeveldbTokens(join(root, 'Local Storage', 'leveldb')), cookies: [...cookies] };
}

export async function discoverWorkspaces(candidates, requestAuth = authTest) {
  const identities = new Map();
  let attempts = 0;
  for (const xoxc of candidates.tokens) {
    for (const xoxd of candidates.cookies) {
      if (++attempts > MAX_AUTH_ATTEMPTS) return [...identities.values()];
      const identity = await requestAuth({ xoxc, xoxd });
      if (identity?.ok === true) identities.set(identity.team_id, identity);
    }
  }
  return [...identities.values()];
}

export async function runServer(credentials, {
  backend, inherited = process.env, maxLineBytes = MAX_NDJSON_BYTES,
  spawn: start = spawn,
  stdin = process.stdin, stdout = process.stdout, stderr = process.stderr,
  lifecycle = process, shutdownMs = 1000,
} = {}) {
  let child;
  let timer;
  let status;
  let childStatus = 1;
  let stopped = false;
  let terminating = false;
  let exited = false;
  let interrupted = false;
  let reported = false;
  let diagnosticFailed = false;
  const listeners = [];
  const on = (target, event, handler) => {
    target.on(event, handler);
    listeners.push(() => target.off(event, handler));
  };
  const requests = createMcpRequestFilter((response) => stdout.write(`${JSON.stringify(sanitizeMessage(response, credentials))}\n`), { maxLineBytes });
  const responses = createMcpFilter(credentials, { maxLineBytes });
  const stopInput = () => {
    if (stopped) return;
    stopped = true;
    stdin.unpipe(requests);
    stdin.pause();
    requests.unpipe(child?.stdin);
    requests.destroy();
    if (child?.stdin && !child.stdin.destroyed) child.stdin.end();
  };
  const report = (message) => {
    if (reported || diagnosticFailed) return;
    reported = true;
    try {
      stderr.write(`${message}\n`, () => {});
    } catch {
      diagnosticFailed = true;
    }
  };
  const signalChild = (signal) => {
    if (!child?.pid || exited) return;
    try {
      child.kill(signal);
    } catch (error) {
      if (error?.code !== 'ESRCH') {
        status ??= 1;
        report('Could not signal Slack MCP server');
      }
    }
  };
  const shutdown = (signal, code) => {
    status ??= code;
    stopInput();
    signalChild(signal);
    if (terminating) return;
    terminating = true;
    clearTimeout(timer);
    timer = setTimeout(() => signalChild('SIGKILL'), shutdownMs);
    timer.unref();
  };
  const fail = (message, discardOutput = false) => {
    status ??= 1;
    if (!interrupted) report(message);
    if (discardOutput) {
      child?.stdout?.unpipe(responses);
      child?.stdout?.destroy();
      responses.unpipe(stdout);
      responses.destroy();
    }
    if (!terminating) shutdown('SIGTERM', 1);
  };
  const deadline = () => {
    if (terminating) return;
    clearTimeout(timer);
    timer = setTimeout(() => fail('Slack MCP server shutdown timed out'), shutdownMs);
    timer.unref();
  };
  const endInput = () => {
    if (stopped || requests.writableEnded) return;
    requests.end();
    deadline();
  };
  on(stdin, 'end', endInput);
  on(stdin, 'close', endInput);
  on(stdin, 'error', () => fail('Slack MCP input failed'));
  on(stdout, 'error', () => fail('Slack MCP output failed', true));
  on(stdout, 'close', () => fail('Slack MCP output closed', true));
  on(stderr, 'error', () => { diagnosticFailed = true; fail('Slack MCP diagnostic output failed'); });
  on(requests, 'error', () => fail('Invalid Maki MCP request'));
  for (const [signal, code] of [['SIGINT', 130], ['SIGTERM', 143]]) {
    on(lifecycle, signal, () => { interrupted = true; shutdown(signal, code); });
  }
  const drained = finished(responses, { cleanup: true }).catch(() => fail('Invalid Slack MCP server output', true));
  let closed = Promise.resolve();
  try {
    const options = serverOptions(credentials, { backend, inherited });
    child = start(options.command, options.args, {
      env: options.env, stdio: ['pipe', 'pipe', 'ignore'],
    });
    closed = new Promise((resolve) => on(child, 'close', (code, signal) => {
      exited = true;
      childStatus = code ?? ({ SIGINT: 130, SIGTERM: 143, SIGKILL: 137 }[signal] ?? 1);
      clearTimeout(timer);
      stopInput();
      if (childStatus !== 0 && status === undefined) report('Slack MCP backend exited before completing; verify Slack is signed in, run auth again, and retry');
      resolve();
    }));
    on(child, 'exit', () => { exited = true; stopInput(); deadline(); });
    on(child, 'error', () => fail('Could not start Slack MCP server', true));
    on(child.stdin, 'error', () => { if (!exited) fail('Slack MCP server input failed'); });
    on(child.stdout, 'error', () => fail('Slack MCP server output failed', true));
    on(child.stdout, 'close', () => {
      if (!child.stdout.readableEnded) fail('Slack MCP server output closed unexpectedly', true);
    });
    child.stdout.pipe(responses).pipe(stdout, { end: false });
    stdin.pipe(requests).pipe(child.stdin);
    if (stdin.readableEnded || stdin.destroyed) endInput();
  } catch {
    fail('Could not start Slack MCP server', true);
  }
  await Promise.all([closed, drained]);
  stopInput();
  child?.stdout?.unpipe(responses);
  responses.unpipe(stdout);
  responses.destroy();
  const flush = (stream) => stream.destroyed ? Promise.resolve() : new Promise((resolve) => {
    try { stream.write('', resolve); } catch { resolve(); }
  });
  await Promise.all([flush(stdout), flush(stderr)]);
  await new Promise((resolve) => setImmediate(resolve));
  clearTimeout(timer);
  for (const remove of listeners) remove();
  lifecycle.exitCode = status ?? childStatus;
  return lifecycle.exitCode;
}

const USAGE = 'Usage: node session.mjs auth [--team WORKSPACE_ID] | serve --backend ABSOLUTE_PATH';

async function main(args) {
  const [command, ...rest] = args;
  if (command === 'auth') {
    if (rest.length !== 0 && (rest.length !== 2 || rest[0] !== '--team' || !TEAM_PATTERN.test(rest[1]))) throw new Error(USAGE);
    const teamId = rest[1];
    const candidates = await extractDesktop();
    if (candidates.tokens.length === 0 || candidates.cookies.length === 0) throw new Error('Could not find a Slack desktop session; keep Slack signed in and try again');
    if (!teamId) {
      const workspaces = await discoverWorkspaces(candidates);
      if (workspaces.length === 0) throw new Error('No valid Slack workspace session was found');
      for (const workspace of workspaces) process.stdout.write(`${workspace.team}\t${workspace.team_id}\t${workspace.user_id}\n`);
      return;
    }
    const identity = await authorizeTeam(candidates, teamId);
    if (!identity) throw new Error('No valid Slack desktop session matched that workspace ID');
    process.stdout.write(`Saved Slack desktop credentials in macOS Keychain for ${identity.team} (${identity.team_id}); connector tools are read-only.\n`);
    return;
  }
  if (command === 'serve') {
    if (rest.length !== 2 || rest[0] !== '--backend') throw new Error(USAGE);
    const backend = validateBackend(rest[1]);
    await runServer(await loadCredentials(), { backend });
    return;
  }
  throw new Error(USAGE);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch((error) => {
    let message = 'Slack MCP command failed; verify your Slack desktop session and retry';
    try {
      const detail = error?.message;
      if ([
        USAGE,
        'Slack MCP backend must be an absolute executable path',
        'Could not find a Slack desktop session; keep Slack signed in and try again',
        'No valid Slack workspace session was found',
        'No valid Slack desktop session matched that workspace ID',
        'Could not save Slack MCP credentials in macOS Keychain',
        'Slack MCP credentials are unavailable in macOS Keychain; run the auth command again',
        'Could not safely read Slack desktop LevelDB; quit Slack and try again',
      ].includes(detail)) message = detail;
    } catch {}
    process.stderr.write(`${message}\n`);
    process.exitCode = 1;
  });
}
