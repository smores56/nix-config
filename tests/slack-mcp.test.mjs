import test from 'node:test';
import assert from 'node:assert/strict';
import { createCipheriv, createHash, pbkdf2Sync } from 'node:crypto';
import { lstat, mkdir, mkdtemp, open, readFile, readdir, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { PassThrough, Readable, Writable } from 'node:stream';
import { EventEmitter } from 'node:events';
import { spawn } from 'node:child_process';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';
import {
  KEYCHAIN_ACCOUNT, KEYCHAIN_SERVICE, MAX_NDJSON_BYTES, READ_TOOLS, authTest, authorizeTeam, createMcpFilter, createMcpRequestFilter, decryptCookie, extractDesktop,
  loadCredentials, runServer, sanitizeMessage, sanitizeSchema,
  saveCredentials, serverOptions, validateCredentials,
} from '../modules/features/ai/slack-mcp/session.mjs';
import { extractTokens } from '../modules/features/ai/slack-mcp/leveldb.mjs';

const sessionUrl = new URL('../modules/features/ai/slack-mcp/session.mjs', import.meta.url);
const backend = '/synthetic/store/slack-mcp-server/bin/slack-mcp-server';
const password = 'synthetic-safe-storage-password';
const credentials = { xoxc: 'xoxc-test-token', xoxd: 'xoxd-test-cookie', team_id: 'TTEST1', user_id: 'UTEST1' };
const identity = { ok: true, team: 'Test Workspace', team_id: 'TTEST1', user_id: 'UTEST1' };
const tools = 'conversations_history,conversations_replies,conversations_search_messages,conversations_unreads,channels_list,channels_me,users_search,usergroups_list';

function encryptedCookie(value, host = null) {
  const key = pbkdf2Sync(password, 'saltysalt', 1003, 16, 'sha1');
  const cipher = createCipheriv('aes-128-cbc', key, Buffer.alloc(16, 32));
  const plaintext = Buffer.concat([host === null ? Buffer.alloc(0) : createHash('sha256').update(host).digest(), Buffer.from(value)]);
  return Buffer.concat([Buffer.from('v10'), cipher.update(plaintext), cipher.final()]);
}

async function temporary(t) {
  const root = await mkdtemp(join(tmpdir(), 'slack-mcp-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  return root;
}

function cookieDatabase(path, version, rows) {
  const db = new DatabaseSync(path);
  try {
    db.exec('CREATE TABLE meta (key TEXT, value TEXT); CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB)');
    db.prepare('INSERT INTO meta VALUES (?, ?)').run('version', String(version));
    const insert = db.prepare('INSERT INTO cookies VALUES (?, ?, ?, ?)');
    for (const row of rows) insert.run(...row);
  } finally {
    db.close();
  }
}

test('decrypts pre-24 v10 cookies without removing a host prefix', () => {
  assert.equal(decryptCookie(encryptedCookie('xoxd-test%2F%2B%3D'), password, '.slack.com', 23), 'xoxd-test%2F%2B%3D');
  assert.equal(decryptCookie(encryptedCookie('xoxd-test', '.slack.com'), password, '.slack.com', 23), null);
});

test('decrypts v24+ v10 cookies only after verifying the exact host hash', () => {
  const encrypted = encryptedCookie('xoxd-test%2F%2B%3D', '.slack.com');
  assert.equal(decryptCookie(encrypted, password, '.slack.com', 24), 'xoxd-test%2F%2B%3D');
  assert.equal(decryptCookie(encrypted, password, '.slack.com', 25), 'xoxd-test%2F%2B%3D');
  assert.equal(decryptCookie(encrypted, password, 'slack.com', 24), null);
  assert.equal(decryptCookie(encryptedCookie('xoxd-test'), password, '.slack.com', 24), null);
});

test('rejects unsupported ciphertext, invalid metadata, bad keys and non-Slack hosts', () => {
  const encrypted = encryptedCookie('xoxd-test');
  assert.equal(decryptCookie(Buffer.concat([Buffer.from('v11'), encrypted.subarray(3)]), password, '.slack.com', 23), null);
  assert.equal(decryptCookie(encrypted.subarray(0, 7), password, '.slack.com', 23), null);
  assert.equal(decryptCookie(encrypted, 'wrong-password', '.slack.com', 23), null);
  assert.equal(decryptCookie(encrypted, password, '.slack.com', null), null);
  assert.equal(decryptCookie(encrypted, password, 'evilslack.com', 23), null);
  assert.equal(decryptCookie(encryptedCookie('xoxp-not-a-cookie'), password, '.slack.com', 23), null);
});

test('extracts only complete teams tokens from Chromium Latin1 and UTF16LE localConfig JSON', () => {
  for (const marker of [0, 1]) {
    const config = { teams: {
      TFIRST: { token: 'xoxc-first-token', name: marker === 0 ? 'Workspace 🟦' : 'Café' },
      TSECOND: { token: 'xoxc-second-token' },
      TDUPLICATE: { token: 'xoxc-first-token' },
      TINVALID: { token: 'xoxc-invalid-token!fragment' },
      TNEWLINE: { token: 'xoxc-invalid-newline\n' },
      TSHORT: { token: 'xoxc-ab' },
      TSTRING: 'xoxc-not-a-team-token',
    }, token: 'xoxc-outside-teams' };
    assert.deepEqual(extractTokens(chromiumValue(JSON.stringify(config), marker)).sort(), ['xoxc-first-token', 'xoxc-second-token']);
    assert.deepEqual(extractTokens(chromiumValue(JSON.stringify({ teams: [{ token: credentials.xoxc }] }), marker)), [credentials.xoxc]);
  }
  for (const value of [Buffer.from('"xoxc-fragment-token"'),
    chromiumValue('{"teams":{"TTEST1":{"token":"xoxc-truncated-token'),
    chromiumValue(JSON.stringify({ token: credentials.xoxc })),
    Buffer.concat([Buffer.from([2]), Buffer.from(JSON.stringify({ teams: [{ token: credentials.xoxc }] }))]),
    Buffer.from([0, 123]), Buffer.alloc(0)]) {
    assert.deepEqual(extractTokens(value), []);
  }
});

test('pins the exact read-tool allowlist and removes every inherited Slack MCP setting', () => {
  const inherited = {
    PATH: '/synthetic/bin', HOME: '/synthetic/home', TMPDIR: '/synthetic/tmp', OPENAI_API_KEY: 'unrelated-secret', SLACK_MCP_XOXP_TOKEN: 'xoxp-inherited',
    SLACK_MCP_XOXB_TOKEN: 'xoxb-inherited', SLACK_MCP_XOXC_TOKEN: 'xoxc-inherited',
    SLACK_MCP_XOXD_TOKEN: 'xoxd-inherited', SLACK_MCP_ADD_MESSAGE_TOOL: 'true',
    SLACK_MCP_REACTION_TOOL: 'true', SLACK_MCP_MARK_TOOL: 'true',
    SLACK_MCP_ENABLED_TOOLS: 'usergroups_update', SLACK_MCP_SERVER_CA_INSECURE: 'true',
    SLACK_MCP_FUTURE_WRITE_SETTING: 'true', SLACK_MCP_LOG_LEVEL: 'debug',
    SLACK_TOKEN: 'xoxb-other-secret', SLACK_BOT_TOKEN: 'xoxb-another-secret', SLACK_COOKIE: 'd=inherited',
    ANTHROPIC_API_KEY: 'private-key', GOOGLE_API_KEY: 'private-key', AWS_SECRET_ACCESS_KEY: 'private-key',
    NODE_OPTIONS: '--require /synthetic/injected.cjs', NODE_EXTRA_CA_CERTS: '/synthetic/untrusted.pem',
    HTTPS_PROXY: 'https://synthetic-proxy.invalid', SLACK_MCP_BACKEND: '/synthetic/untrusted-backend',
  };
  const options = serverOptions(credentials, { backend, inherited });
  assert.equal(READ_TOOLS.join(','), tools);
  assert.equal(options.command, backend);
  assert.deepEqual(options.args, ['--transport', 'stdio', '--enabled-tools', tools]);
  assert.deepEqual(options.env, {
    PATH: inherited.PATH, HOME: inherited.HOME, TMPDIR: inherited.TMPDIR,
    SLACK_MCP_XOXC_TOKEN: credentials.xoxc,
    SLACK_MCP_XOXD_TOKEN: credentials.xoxd, SLACK_MCP_LOG_LEVEL: 'error',
  });
  assert.equal(inherited.SLACK_MCP_LOG_LEVEL, 'debug');
  assert.ok(!options.args.join(' ').includes(credentials.xoxc));
  assert.ok(!options.args.join(' ').includes(credentials.xoxd));
});

test('requires an explicit absolute backend path without PATH npm or environment fallbacks', () => {
  for (const candidate of [undefined, null, '', 'slack-mcp-server', 'npm', './server', '../server', '~/server', 'file:///synthetic/server', '/synthetic/server\nsecret', '/synthetic/server\0secret', 42]) {
    assert.throws(() => serverOptions(credentials, { backend: candidate, inherited: { PATH: '/synthetic/bin', SLACK_MCP_BACKEND: backend } }), {
      message: 'Slack MCP backend must be an absolute executable path',
    });
  }
  assert.throws(() => serverOptions(credentials), /absolute executable path/);
  assert.throws(() => serverOptions({ ...credentials, xoxc: 'xoxp-rejected' }, { backend }), /credentials/);
  const options = serverOptions(credentials, { backend, inherited: {} });
  assert.equal(options.command, backend);
  assert.deepEqual(Object.keys(options.env).sort(), ['SLACK_MCP_LOG_LEVEL', 'SLACK_MCP_XOXC_TOKEN', 'SLACK_MCP_XOXD_TOKEN']);
});

test('CLI rejects missing relative duplicate and unknown backend flags before accessing desktop or Keychain', { timeout: 5000 }, async () => {
  for (const args of [[], ['serve'], ['serve', '--backend'], ['serve', '--backend', 'npm'], ['serve', '--backend', backend, '--backend', backend], ['serve', '--other', backend], ['auth', '--backend', backend], ['auth', '--team'], ['auth', '--team', 'invalid'], ['auth', '--team', 'TTEST1', '--extra']]) {
    const child = spawn(process.execPath, [fileURLToPath(sessionUrl), ...args], {
      env: { PATH: '/nonexistent', HOME: '/nonexistent', NODE_NO_WARNINGS: '1', SLACK_MCP_BACKEND: backend },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let output = '';
    let diagnostics = '';
    child.stdout.on('data', (chunk) => { output += chunk; });
    child.stderr.on('data', (chunk) => { diagnostics += chunk; });
    assert.equal(await new Promise((resolve) => child.once('close', resolve)), 1);
    assert.equal(output, '');
    assert.match(diagnostics, /Usage:|absolute executable path/);
    assert.doesNotMatch(diagnostics, /Keychain|desktop|xoxc-|xoxd-/);
  }
});

test('CLI auth needs no backend and reads only an explicitly empty synthetic home', { timeout: 3000 }, async (t) => {
  const root = await temporary(t);
  const child = spawn(process.execPath, [fileURLToPath(sessionUrl), 'auth'], {
    env: { PATH: '/nonexistent', HOME: root, NODE_NO_WARNINGS: '1' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let output = '';
  let diagnostics = '';
  child.stdout.on('data', (chunk) => { output += chunk; });
  child.stderr.on('data', (chunk) => { diagnostics += chunk; });
  assert.equal(await new Promise((resolve) => child.once('close', resolve)), 1);
  assert.equal(output, '');
  assert.equal(diagnostics, 'Could not find a Slack desktop session; keep Slack signed in and try again\n');
  assert.deepEqual(await readdir(root), []);
});

test('CLI hides unexpected exceptions including non-Errors and throwing message getters', { timeout: 5000 }, async (t) => {
  const root = await temporary(t);
  const secret = JSON.stringify(`${credentials.xoxc} ${credentials.xoxd}`);
  for (const failure of [`new Error(${secret})`, secret, `Object.defineProperty({}, 'message', { get() { throw new Error(${secret}); } })`]) {
    const source = `import os from 'node:os';
      import { syncBuiltinESMExports } from 'node:module';
      os.homedir = () => { throw ${failure}; };
      syncBuiltinESMExports();
      process.argv = [process.execPath, ${JSON.stringify(fileURLToPath(sessionUrl))}, 'auth'];
      await import(${JSON.stringify(sessionUrl.href)});`;
    const child = spawn(process.execPath, ['--input-type=module', '-e', source], {
      env: { PATH: '/nonexistent', HOME: root, NODE_NO_WARNINGS: '1' },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let output = '';
    let diagnostics = '';
    child.stdout.on('data', (chunk) => { output += chunk; });
    child.stderr.on('data', (chunk) => { diagnostics += chunk; });
    assert.equal(await new Promise((resolve) => child.once('close', resolve)), 1);
    assert.equal(output, '');
    assert.equal(diagnostics, 'Slack MCP command failed; verify your Slack desktop session and retry\n');
  }
  assert.deepEqual(await readdir(root), []);
});

test('validates credential object values and returns only the chosen fields', () => {
  assert.deepEqual(validateCredentials({ ...credentials, extra: 'ignored' }), credentials);
  for (const value of [null, [], {}, { ...credentials, xoxc: ['xoxc-array'] },
    { ...credentials, xoxc: 'xoxp-wrong' }, { ...credentials, xoxd: 'xoxc-wrong' },
    { ...credentials, xoxd: 'xoxd-cookie\nInjected: value' },
    { ...credentials, team_id: 'wrong' }, { ...credentials, user_id: null }]) {
    assert.throws(() => validateCredentials(value), /credentials/i);
  }
});

test('stores validated credentials through Keychain stdin without secrets in process arguments', async () => {
  assert.equal(KEYCHAIN_SERVICE, 'maki-slack-mcp');
  assert.equal(KEYCHAIN_ACCOUNT, 'desktop-session');
  let calls = 0;
  await saveCredentials({ ...credentials, extra: 'not-persisted' }, (command, args, options) => {
    calls++;
    assert.equal(command, '/usr/bin/security');
    assert.ok(!JSON.stringify(args).includes(credentials.xoxc));
    assert.ok(!JSON.stringify(args).includes(credentials.xoxd));
    assert.equal(options.encoding, 'utf8');
    assert.equal(options.timeout, 30000);
    if (calls === 1) {
      assert.deepEqual(args, ['-i']);
      assert.deepEqual(options.stdio, ['pipe', 'ignore', 'ignore']);
      const prefix = `add-generic-password -U -a ${KEYCHAIN_ACCOUNT} -s ${KEYCHAIN_SERVICE} -X `;
      assert.ok(options.input.startsWith(prefix));
      const encoded = options.input.slice(prefix.length).trim();
      assert.match(encoded, /^[a-f0-9]+$/);
      assert.deepEqual(JSON.parse(Buffer.from(encoded, 'hex').toString()), credentials);
      return { status: 0 };
    }
    assert.deepEqual(args, ['find-generic-password', '-a', KEYCHAIN_ACCOUNT, '-s', KEYCHAIN_SERVICE, '-w']);
    return { status: 0, stdout: `${JSON.stringify(credentials)}\n` };
  });
  assert.equal(calls, 2);
});

test('rejects invalid credentials before accessing Keychain', async () => {
  let called = false;
  await assert.rejects(saveCredentials({ ...credentials, xoxc: 'xoxp-invalid' }, () => { called = true; }), /credentials/i);
  assert.equal(called, false);
});

test('rejects oversized Keychain input before starting a subprocess', async () => {
  let called = false;
  await assert.rejects(saveCredentials({ ...credentials, xoxc: `xoxc-${'a'.repeat(3000)}` }, () => { called = true; }), /Keychain/);
  assert.equal(called, false);
});

test('fails closed when Keychain writes fail or stored credentials differ', async () => {
  for (const result of [{ status: 1 }, { error: new Error(credentials.xoxc) }, { status: 0, stdout: JSON.stringify({ ...credentials, team_id: 'TOTHER' }) }]) {
    await assert.rejects(saveCredentials(credentials, () => result), (error) => (
      /Keychain/.test(error.message) && !error.message.includes(credentials.xoxc)
    ));
  }
});

test('loads only a valid Keychain item and suppresses errors containing secrets', async () => {
  assert.deepEqual(await loadCredentials((command, args, options) => {
    assert.equal(command, '/usr/bin/security');
    assert.deepEqual(args, ['find-generic-password', '-a', KEYCHAIN_ACCOUNT, '-s', KEYCHAIN_SERVICE, '-w']);
    assert.deepEqual(options.stdio, ['ignore', 'pipe', 'ignore']);
    assert.equal(options.maxBuffer, 65536);
    return { status: 0, stdout: JSON.stringify(credentials) };
  }), credentials);
  for (const result of [{ status: 44, stdout: credentials.xoxc }, { status: 0, stdout: `invalid ${credentials.xoxd}` }, { status: 0, stdout: JSON.stringify({ ...credentials, xoxd: 'bad-sensitive-test' }) }]) {
    await assert.rejects(loadCredentials(() => result), (error) => (
      /Keychain/.test(error.message) && !/xoxc-|xoxd-|sensitive-test/.test(error.message)
    ));
  }
  await assert.rejects(loadCredentials(() => { throw new Error(credentials.xoxc); }), (error) => !error.message.includes(credentials.xoxc));
});

test('auth.test sends bearer and session-cookie credentials without redirects', async () => {
  const result = await authTest(credentials, async (url, options) => {
    assert.equal(url, 'https://slack.com/api/auth.test');
    assert.equal(options.method, 'GET');
    assert.equal(options.headers.Authorization, `Bearer ${credentials.xoxc}`);
    assert.equal(options.headers.Cookie, `d=${credentials.xoxd}`);
    assert.equal(options.redirect, 'error');
    assert.ok(options.signal instanceof AbortSignal);
    return { ok: true, json: async () => ({ ...identity, secret: credentials.xoxc }) };
  });
  assert.deepEqual(result, identity);
});

test('auth.test rejects non-true success, invalid identities and errors without secret details', async () => {
  for (const response of [{ ...identity, ok: false }, { ...identity, ok: 'true' },
    { ...identity, team_id: 'invalid' }, { ...identity, user_id: null }]) {
    assert.equal(await authTest(credentials, async () => ({ ok: true, json: async () => response })), null);
  }
  assert.equal(await authTest(credentials, async () => { throw new Error(credentials.xoxc); }), null);
  assert.equal(await authTest(credentials, async () => ({ ok: false })), null);
  let called = false;
  assert.equal(await authTest({ ...credentials, xoxd: 'invalid' }, async () => { called = true; }), null);
  assert.equal(called, false);
});

test('auth does not persist failed or different-team sessions', async () => {
  let saved = false;
  const persist = async () => { saved = true; };
  const candidates = { tokens: [credentials.xoxc], cookies: [credentials.xoxd] };
  assert.equal(await authorizeTeam(candidates, 'TTEST1', async () => ({ ...identity, ok: false }), persist), null);
  assert.equal(await authorizeTeam(candidates, 'TTEST1', async () => ({ ...identity, team_id: 'TOTHER' }), persist), null);
  assert.equal(saved, false);
});

test('auth persists only a successful credential pair for the exact requested team', async () => {
  let saved;
  const candidates = { tokens: ['xoxc-other-team', credentials.xoxc], cookies: [credentials.xoxd] };
  const result = await authorizeTeam(candidates, 'TTEST1', async (pair) => (
    pair.xoxc === credentials.xoxc ? identity : { ...identity, team_id: 'TOTHER' }
  ), async (value) => { saved = value; });
  assert.deepEqual(result, identity);
  assert.deepEqual(saved, credentials);
});

function varint(value) {
  value = BigInt(value);
  const bytes = [];
  do {
    bytes.push(Number(value & 127n) | (value >= 128n ? 128 : 0));
    value >>= 7n;
  } while (value > 0n);
  return Buffer.from(bytes);
}

function uint32(value) {
  const buffer = Buffer.alloc(4);
  buffer.writeUInt32LE(value >>> 0);
  return buffer;
}

function maskedCrc(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0x82f63b78 : 0);
  }
  crc = ~crc >>> 0;
  return (((crc >>> 15) | (crc << 17)) + 0xa282ead8) >>> 0;
}

function chromiumValue(value, marker = 1) {
  return Buffer.concat([Buffer.from([marker]), Buffer.from(value, marker === 0 ? 'utf16le' : 'latin1')]);
}

function storageKey(name = 'localConfig_v2', marker = 1, origin = 'https://app.slack.com') {
  return Buffer.concat([Buffer.from(`_${origin}\0`), chromiumValue(name, marker)]);
}

function localRecord(sequence, token = credentials.xoxc, { type = 1, marker = 1, key = storageKey(), value } = {}) {
  return { sequence: BigInt(sequence), type, key,
    value: value ?? (type === 0 ? Buffer.alloc(0) : chromiumValue(JSON.stringify({ teams: { TTEST1: { token } } }), marker)),
  };
}

function internalKey(record) {
  const trailer = Buffer.alloc(8);
  trailer.writeBigUInt64LE((record.sequence << 8n) | BigInt(record.type));
  return Buffer.concat([record.key, trailer]);
}

function entriesBlock(entries, interval = 2) {
  const chunks = [];
  const restarts = [];
  let previous = Buffer.alloc(0);
  let offset = 0;
  for (let index = 0; index < entries.length; index++) {
    const [key, value] = entries[index];
    let shared = 0;
    if (index % interval === 0) restarts.push(offset);
    else while (shared < Math.min(key.length, previous.length) && key[shared] === previous[shared]) shared++;
    const entry = Buffer.concat([varint(shared), varint(key.length - shared), varint(value.length), key.subarray(shared), value]);
    chunks.push(entry);
    offset += entry.length;
    previous = key;
  }
  if (entries.length === 0) restarts.push(0);
  return Buffer.concat([...chunks, ...restarts.map(uint32), uint32(restarts.length)]);
}

function snappyLiteral(buffer) {
  const length = buffer.length - 1;
  if (length < 60) return Buffer.concat([Buffer.from([length << 2]), buffer]);
  const bytes = length < 256 ? 1 : length < 65536 ? 2 : length < 16777216 ? 3 : 4;
  const header = Buffer.alloc(1 + bytes);
  header[0] = (59 + bytes) << 2;
  header.writeUIntLE(length, 1, bytes);
  return Buffer.concat([header, buffer]);
}

function snappy(buffer, kind = 2) {
  const chunks = [varint(buffer.length)];
  let offset = 1;
  let literalStart = 0;
  while (offset < buffer.length) {
    let length = 0;
    while (length < (kind === 1 ? 11 : 64) && offset + length < buffer.length && buffer[offset + length] === buffer[offset - 1]) length++;
    if (length < 4) {
      offset++;
      continue;
    }
    if (offset > literalStart) chunks.push(snappyLiteral(buffer.subarray(literalStart, offset)));
    const copy = Buffer.alloc(kind === 1 ? 2 : kind === 2 ? 3 : 5);
    copy[0] = kind === 1 ? ((length - 4) << 2) | 1 : ((length - 1) << 2) | kind;
    copy[1] = 1;
    chunks.push(copy);
    offset += length;
    literalStart = offset;
  }
  if (literalStart < buffer.length) chunks.push(snappyLiteral(buffer.subarray(literalStart)));
  return Buffer.concat(chunks);
}

function storedBlock(buffer, encode = null) {
  const body = Buffer.concat([encode ? encode(buffer) : buffer, Buffer.from([encode ? 1 : 0])]);
  return Buffer.concat([body, uint32(maskedCrc(body))]);
}

function tableFile(records, { encode = null, data, blockSize = records.length || 1, indexEncode = null } = {}) {
  const sorted = [...records].sort((left, right) => Buffer.compare(left.key, right.key) || (left.sequence > right.sequence ? -1 : left.sequence < right.sequence ? 1 : right.type - left.type));
  const entries = sorted.map((record) => [internalKey(record), record.value]);
  const blocks = [];
  const handles = [];
  let offset = 0;
  for (let start = 0; start < entries.length; start += blockSize) {
    const group = entries.slice(start, start + blockSize);
    const block = storedBlock(data ?? entriesBlock(group), encode);
    handles.push([group.at(-1)[0], Buffer.concat([varint(offset), varint(block.length - 5)])]);
    blocks.push(block);
    offset += block.length;
  }
  const meta = storedBlock(entriesBlock([]));
  const index = storedBlock(entriesBlock(handles), indexEncode);
  const footer = Buffer.alloc(48);
  Buffer.concat([varint(offset), varint(meta.length - 5), varint(offset + meta.length), varint(index.length - 5)]).copy(footer);
  footer.writeBigUInt64LE(0xdb4775248b80fb57n, 40);
  return Buffer.concat([...blocks, meta, index, footer]);
}

function writeBatch(records) {
  const header = Buffer.alloc(12);
  header.writeBigUInt64LE(records[0]?.sequence ?? 0n);
  header.writeUInt32LE(records.length, 8);
  return Buffer.concat([header, ...records.flatMap((record) => [Buffer.from([record.type]), varint(record.key.length), record.key,
    ...(record.type === 1 ? [varint(record.value.length), record.value] : []),
  ])]);
}

function walFile(batches) {
  const chunks = [];
  let offset = 0;
  for (const batch of batches) {
    let position = 0;
    let first = true;
    do {
      let remaining = 32768 - offset % 32768;
      if (remaining < 7) {
        chunks.push(Buffer.alloc(remaining));
        offset += remaining;
        remaining = 32768;
      }
      const length = Math.min(batch.length - position, remaining - 7);
      const last = position + length === batch.length;
      const type = first ? (last ? 1 : 2) : (last ? 4 : 3);
      const body = Buffer.concat([Buffer.from([type]), batch.subarray(position, position + length)]);
      chunks.push(uint32(maskedCrc(body)), Buffer.from([length & 255, length >>> 8]), body);
      offset += 7 + length;
      position += length;
      first = false;
    } while (position < batch.length);
  }
  return Buffer.concat(chunks);
}

async function writeLeveldbManifest(directory) {
  const files = (await readdir(directory, { withFileTypes: true })).filter((entry) => entry.isFile() && /^\d+\.(?:ldb|sst|log)$/.test(entry.name));
  const logs = files.filter((entry) => entry.name.endsWith('.log')).map((entry) => Number.parseInt(entry.name, 10));
  const comparator = Buffer.from('leveldb.BytewiseComparator');
  const smallest = internalKey(localRecord((1n << 56n) - 1n, undefined, { key: Buffer.from([0]) }));
  const largest = internalKey(localRecord(0, undefined, { key: Buffer.from([255]) }));
  const edit = [varint(1), varint(comparator.length), comparator,
    varint(2), varint(logs.length ? Math.min(...logs) : 0),
    varint(3), varint(1000001), varint(4), varint((1n << 56n) - 1n), varint(9), varint(0)];
  for (const entry of files.filter((entry) => !entry.name.endsWith('.log'))) {
    const metadata = await lstat(join(directory, entry.name));
    edit.push(varint(7), varint(0), varint(Number.parseInt(entry.name, 10)), varint(metadata.size),
      varint(smallest.length), smallest, varint(largest.length), largest);
  }
  await writeFile(join(directory, 'MANIFEST-1000000'), walFile([Buffer.concat(edit)]));
  await writeFile(join(directory, 'CURRENT'), 'MANIFEST-1000000\n');
}

async function writeLeveldbFile(path, content) {
  await writeFile(path, content);
  await writeLeveldbManifest(dirname(path));
}

async function leveldbDirectory(t) {
  const root = await temporary(t);
  const directory = join(root, 'Local Storage', 'leveldb');
  await mkdir(directory, { recursive: true });
  return { root, directory };
}

async function syntheticExtraction(root) {
  return extractDesktop(root, () => { throw new Error('Synthetic extraction must not access Keychain'); });
}

test('desktop extraction reads only synthetic Slack cookie hosts and LevelDB file types without changing databases', async (t) => {
  const root = await temporary(t);
  await mkdir(join(root, 'Network'));
  await mkdir(join(root, 'Local Storage', 'leveldb'), { recursive: true });
  const cookies = join(root, 'Cookies');
  const network = join(root, 'Network', 'Cookies');
  cookieDatabase(cookies, 23, [
    ['.slack.com', 'd', 'xoxd-plain%2F%3D', Buffer.alloc(0)],
    ['evilslack.com', 'd', 'xoxd-evil', Buffer.alloc(0)],
    ['.slack.com', 'other', 'xoxd-other', Buffer.alloc(0)],
    ['.slack.com.evil', 'd', 'xoxd-evil-suffix', Buffer.alloc(0)],
  ]);
  cookieDatabase(network, 24, [
    ['app.slack.com', 'd', '', encryptedCookie('xoxd-encrypted', 'app.slack.com')],
    ['.slack.com', 'd', 'xoxd-bypass', encryptedCookie('xoxd-wrong-host', 'other.slack.com')],
  ]);
  const directory = join(root, 'Local Storage', 'leveldb');
  const latest = chromiumValue(JSON.stringify({ teams: { TPLAIN: { token: 'xoxc-plain-token' }, TWIDE: { token: 'xoxc-wide-token' } } }));
  const fixtures = [
    ['001.log', walFile([writeBatch([localRecord(30, undefined, { value: latest })])])],
    ['002.ldb', tableFile([localRecord(20, 'xoxc-stale-token', { marker: 0 })])],
    ['003.sst', tableFile([localRecord(10, 'xoxc-stale-token')])],
    ['004.txt', Buffer.from('"xoxc-raw-fragment"')],
    ['005.ldb', tableFile([
      localRecord(40, 'xoxc-unrelated-key', { key: storageKey('unrelated') }),
      localRecord(41, 'xoxc-unrelated-origin', { key: storageKey('localConfig_v2', 1, 'https://app.slack.com.evil') }),
    ])],
    ['ignored.txt', tableFile([localRecord(90, 'xoxc-ignored-token')])],
    ['ignored.ldb', tableFile([localRecord(91, 'xoxc-ignored-name')])],
    ['LOCK', Buffer.from('synthetic-lock')],
  ];
  for (const [name, buffer] of fixtures) await writeLeveldbFile(join(directory, name), buffer);
  await symlink(join(directory, 'ignored.txt'), join(directory, '999.sst'));
  await writeLeveldbManifest(directory);
  const paths = [cookies, network, join(directory, 'CURRENT'), join(directory, 'MANIFEST-1000000'), ...fixtures.map(([name]) => join(directory, name))];
  const before = await Promise.all(paths.map((path) => readFile(path)));
  const modified = await Promise.all(paths.map(async (path) => (await lstat(path)).mtimeMs));
  const names = await readdir(directory);
  let passwordReads = 0;
  const result = await extractDesktop(root, async () => { passwordReads++; return password; });
  assert.deepEqual(result.tokens.sort(), ['xoxc-plain-token', 'xoxc-wide-token']);
  assert.deepEqual(result.cookies.sort(), ['xoxd-encrypted', 'xoxd-plain%2F%3D']);
  assert.equal(passwordReads, 1);
  assert.deepEqual(await Promise.all(paths.map((path) => readFile(path))), before);
  assert.deepEqual(await Promise.all(paths.map(async (path) => (await lstat(path)).mtimeMs)), modified);
  assert.deepEqual(await readdir(directory), names);
});

test('reads synthetic persistent cookie journals without changing database journal or directory contents', async (t) => {
  const root = await temporary(t);
  const path = join(root, 'Cookies');
  cookieDatabase(path, 23, [['.slack.com', 'd', credentials.xoxd, Buffer.alloc(0)]]);
  const database = new DatabaseSync(path);
  try {
    database.exec('PRAGMA journal_mode = PERSIST');
    database.prepare('UPDATE cookies SET value = ?').run('xoxd-journal-cookie');
  } finally {
    database.close();
  }
  const names = (await readdir(root)).sort();
  assert.ok(names.includes('Cookies-journal'));
  const paths = names.map((name) => join(root, name));
  const before = await Promise.all(paths.map((path) => readFile(path)));
  const modified = await Promise.all(paths.map(async (path) => (await lstat(path)).mtimeMs));
  assert.deepEqual(await syntheticExtraction(root), { tokens: [], cookies: ['xoxd-journal-cookie'] });
  assert.deepEqual((await readdir(root)).sort(), names);
  assert.deepEqual(await Promise.all(paths.map((path) => readFile(path))), before);
  assert.deepEqual(await Promise.all(paths.map(async (path) => (await lstat(path)).mtimeMs)), modified);
});

test('reads live synthetic cookie WAL without changing database or WAL bytes', async (t) => {
  const root = await temporary(t);
  const path = join(root, 'Cookies');
  cookieDatabase(path, 23, [['.slack.com', 'd', credentials.xoxd, Buffer.alloc(0)]]);
  const writer = new DatabaseSync(path);
  t.after(() => writer.close());
  writer.exec('PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0');
  writer.prepare('UPDATE cookies SET value = ?').run('xoxd-current-wal-cookie');
  const names = (await readdir(root)).sort();
  assert.ok(names.includes('Cookies-wal'));
  const paths = [path, `${path}-wal`];
  const before = await Promise.all(paths.map((path) => readFile(path)));
  const modified = await Promise.all(paths.map(async (path) => (await lstat(path)).mtimeMs));
  assert.deepEqual(await syntheticExtraction(root), { tokens: [], cookies: ['xoxd-current-wal-cookie'] });
  assert.deepEqual((await readdir(root)).sort(), names);
  assert.deepEqual(await Promise.all(paths.map((path) => readFile(path))), before);
  assert.deepEqual(await Promise.all(paths.map(async (path) => (await lstat(path)).mtimeMs)), modified);
});

function extractTokensFromRawFixture(buffer) {
  return [...buffer.toString('latin1').matchAll(/xoxc-[A-Za-z0-9-]+/g)].map((match) => match[0]);
}

test('decodes compressed SST copy tags and returns the entire repeated workspace token', async (t) => {
  const { root, directory } = await leveldbDirectory(t);
  const token = `xoxc-${'A'.repeat(256)}-${'B'.repeat(192)}-complete-token`;
  for (const kind of [1, 2, 3]) {
    const key = storageKey('localConfig_v2', kind === 2 ? 0 : 1);
    const records = [localRecord(20, token, { key }), localRecord(10, 'xoxc-stale-token', { key }),
      localRecord(1, 'xoxc-unrelated-token', { key: storageKey('zz-other') })];
    const table = tableFile(records, { encode: (buffer) => snappy(buffer, kind) });
    assert.ok(table.length < tableFile(records).length);
    assert.ok(Math.max(...extractTokensFromRawFixture(table).map((value) => value.length)) < token.length);
    await writeLeveldbFile(join(directory, `${kind}.sst`), table);
    assert.deepEqual((await syntheticExtraction(root)).tokens, [token]);
  }
});

test('decodes Snappy COPY_1 high offset bits and COPY_2 COPY_4 non-overlapping references', async (t) => {
  const { root, directory } = await leveldbDirectory(t);
  const token = 'xoxc-complete-synthetic-token';
  const value = chromiumValue(JSON.stringify({ teams: { TTEST1: { token } }, padding: 'p'.repeat(300), duplicate: token }));
  for (const kind of [1, 2, 3]) {
    const encode = (buffer) => {
      const first = buffer.indexOf(token);
      const second = buffer.indexOf(token, first + token.length);
      const distance = second - first;
      assert.ok(distance > 255 && distance < 2048);
      const length = kind === 1 ? 11 : token.length;
      const copy = Buffer.alloc(kind === 1 ? 2 : kind === 2 ? 3 : 5);
      copy[0] = kind === 1 ? ((length - 4) << 2) | 1 | ((distance >>> 8) << 5) : ((length - 1) << 2) | kind;
      copy.writeUIntLE(kind === 1 ? distance & 255 : distance, 1, copy.length - 1);
      return Buffer.concat([varint(buffer.length), snappyLiteral(buffer.subarray(0, second)), copy, snappyLiteral(buffer.subarray(second + length))]);
    };
    await writeLeveldbFile(join(directory, `${kind}.sst`), tableFile([localRecord(10, undefined, { value })], { encode }));
    assert.deepEqual((await syntheticExtraction(root)).tokens, [token]);
  }
});

test('uses Chromium string markers for both storage keys and values without mixing origins', async (t) => {
  const { root, directory } = await leveldbDirectory(t);
  const records = [
    localRecord(10, 'xoxc-latin-token', { marker: 1 }),
    localRecord(20, 'xoxc-wide-token', { marker: 0, key: storageKey('localConfig_v2', 0, 'https://workspace.slack.com') }),
    localRecord(30, 'xoxc-not-slack-token', { key: storageKey('localConfig_v2', 1, 'https://evilslack.com') }),
    localRecord(40, 'xoxc-not-https-token', { key: storageKey('localConfig_v2', 1, 'http://app.slack.com') }),
  ];
  await writeLeveldbFile(join(directory, '001.ldb'), tableFile(records));
  assert.deepEqual((await syntheticExtraction(root)).tokens.sort(), ['xoxc-latin-token', 'xoxc-wide-token']);
});

test('selects newest internal sequence across tables and WAL rather than filename or token position', async (t) => {
  const { root, directory } = await leveldbDirectory(t);
  await writeLeveldbFile(join(directory, '999.sst'), tableFile([localRecord(10, 'xoxc-oldest-token')]));
  await writeLeveldbFile(join(directory, '100.ldb'), tableFile([
    localRecord(35, 'xoxc-current-token'), localRecord(30, 'xoxc-middle-token'), localRecord(20, 'xoxc-older-token'),
  ], { blockSize: 1, indexEncode: snappy }));
  await writeLeveldbFile(join(directory, '001.log'), walFile([writeBatch([localRecord(34, 'xoxc-older-wal-token')])]));
  assert.deepEqual((await syntheticExtraction(root)).tokens, ['xoxc-current-token']);
  await writeLeveldbFile(join(directory, '001.log'), walFile([writeBatch([localRecord(36, 'xoxc-newest-wal-token')])]));
  assert.deepEqual((await syntheticExtraction(root)).tokens, ['xoxc-newest-wal-token']);
});

test('preserves 56-bit sequences and fails closed on conflicting equal-sequence records', async (t) => {
  const { root, directory } = await leveldbDirectory(t);
  const sequence = (1n << 56n) - 2n;
  await writeLeveldbFile(join(directory, '999.sst'), tableFile([localRecord(sequence, 'xoxc-high-sequence')]));
  await writeLeveldbFile(join(directory, '001.log'), walFile([writeBatch([localRecord(sequence + 1n, 'xoxc-highest-sequence')])]));
  assert.deepEqual((await syntheticExtraction(root)).tokens, ['xoxc-highest-sequence']);
  await writeLeveldbFile(join(directory, '100.ldb'), tableFile([localRecord(sequence + 1n, 'xoxc-highest-sequence')]));
  assert.deepEqual((await syntheticExtraction(root)).tokens, ['xoxc-highest-sequence']);
  await writeLeveldbFile(join(directory, '100.ldb'), tableFile([localRecord(sequence + 1n, 'xoxc-conflicting-sequence')]));
  assert.deepEqual((await syntheticExtraction(root)).tokens, []);
  await writeLeveldbFile(join(directory, '100.ldb'), tableFile([localRecord(sequence + 1n, undefined, { type: 0 })]));
  assert.deepEqual((await syntheticExtraction(root)).tokens, []);
});

test('honors table and WAL tombstones and does not resurrect tokens from older records', async (t) => {
  const { root, directory } = await leveldbDirectory(t);
  const table = join(directory, '100.sst');
  const log = join(directory, '001.log');
  await writeLeveldbFile(table, tableFile([localRecord(30, undefined, { type: 0 }), localRecord(20, 'xoxc-deleted-token')]));
  await writeLeveldbFile(log, walFile([writeBatch([localRecord(29, 'xoxc-old-wal-token')])]));
  assert.deepEqual((await syntheticExtraction(root)).tokens, []);
  await writeLeveldbFile(log, walFile([writeBatch([localRecord(31, 'xoxc-restored-token')])]));
  assert.deepEqual((await syntheticExtraction(root)).tokens, ['xoxc-restored-token']);
  await writeLeveldbFile(log, walFile([writeBatch([localRecord(32, 'xoxc-transient-token'), localRecord(33, undefined, { type: 0 })])]));
  assert.deepEqual((await syntheticExtraction(root)).tokens, []);
  await writeLeveldbFile(log, walFile([writeBatch([localRecord(34, 'xoxc-after-delete-token')])]));
  assert.deepEqual((await syntheticExtraction(root)).tokens, ['xoxc-after-delete-token']);
});

test('malformed current tables or WAL never fall back to an older valid desktop token', async (t) => {
  for (const extension of ['ldb', 'sst', 'log']) {
    await t.test(extension, async (t) => {
      const { root, directory } = await leveldbDirectory(t);
      await writeLeveldbFile(join(directory, '001.ldb'), tableFile([localRecord(10, 'xoxc-stale-secret')]));
      const current = join(directory, `999.${extension}`);
      const records = [localRecord(20, 'xoxc-newer-secret'), localRecord(21, undefined, { type: 0 })];
      const valid = extension === 'log' ? walFile(records.map((record) => writeBatch([record]))) : tableFile(records, { blockSize: 1 });
      await writeLeveldbFile(current, valid);
      assert.deepEqual((await syntheticExtraction(root)).tokens, []);
      for (const invalid of [valid.subarray(0, -1), Buffer.from('xoxc-corrupt-secret')]) {
        await writeLeveldbFile(current, invalid);
        await assert.rejects(syntheticExtraction(root), (error) => {
          assert.equal(error.message, 'Could not safely read Slack desktop LevelDB; quit Slack and try again');
          assert.doesNotMatch(error.message, /xoxc-|xoxd-|999|001/);
          assert.ok(!error.message.includes(root));
          return true;
        });
      }
    });
  }
});

test('a newer invalid localConfig value suppresses older valid tokens instead of scanning fragments', async (t) => {
  const { root, directory } = await leveldbDirectory(t);
  await writeLeveldbFile(join(directory, '100.ldb'), tableFile([localRecord(10, 'xoxc-stale-token')]));
  for (const value of [
    chromiumValue('{"teams":{"TTEST1":{"token":"xoxc-unfinished-token'),
    chromiumValue(JSON.stringify({ token: 'xoxc-not-in-teams' })),
    chromiumValue(JSON.stringify({ teams: { TTEST1: { token: 'xoxc-token-with-invalid-tail!' } } })),
    Buffer.concat([Buffer.from([2]), Buffer.from('{"teams":{"TTEST1":{"token":"xoxc-wrong-marker"}}}')]),
  ]) {
    await writeLeveldbFile(join(directory, '001.log'), walFile([writeBatch([localRecord(20, undefined, { value })])]));
    assert.deepEqual((await syntheticExtraction(root)).tokens, []);
  }
});

test('reassembles FIRST MIDDLE LAST WAL fragments with per-operation sequences', async (t) => {
  const { root, directory } = await leveldbDirectory(t);
  const value = chromiumValue(JSON.stringify({ padding: 'p'.repeat(100000), teams: { TTEST1: { token: 'xoxc-fragmented-token' } } }));
  await writeLeveldbFile(join(directory, '999.sst'), tableFile([localRecord(10, 'xoxc-old-token')]));
  const fragmented = writeBatch([localRecord(20, undefined, { value })]);
  const records = [localRecord(21, undefined, { type: 0 }), localRecord(22, 'xoxc-after-fragments')];
  await writeLeveldbFile(join(directory, '001.log'), walFile([fragmented]));
  assert.deepEqual((await syntheticExtraction(root)).tokens, ['xoxc-fragmented-token']);
  await writeLeveldbFile(join(directory, '001.log'), walFile([fragmented, writeBatch(records)]));
  assert.deepEqual((await syntheticExtraction(root)).tokens, ['xoxc-after-fragments']);
});

test('accepts WAL block trailer padding and a zero-length FIRST fragment at a header boundary', async (t) => {
  const { root, directory } = await leveldbDirectory(t);
  for (const trailing of [3, 7]) {
    let padding = 32000;
    let batch;
    for (let attempt = 0; attempt < 4; attempt++) {
      batch = writeBatch([localRecord(10, undefined, { key: storageKey('unrelated'), value: Buffer.alloc(padding, 65) })]);
      padding += 32768 - trailing - 7 - batch.length;
    }
    assert.equal(batch.length + 7, 32768 - trailing);
    await writeLeveldbFile(join(directory, '001.log'), walFile([batch, writeBatch([localRecord(11, 'xoxc-after-padding')])]));
    assert.deepEqual((await syntheticExtraction(root)).tokens, ['xoxc-after-padding']);
  }
});

test('rejects malformed raw Snappy lengths offsets truncation and expansion sizes without leaking records', async (t) => {
  const { root, directory } = await leveldbDirectory(t);
  const malformed = [
    Buffer.from([128]),
    varint(32 * 1024 * 1024 + 1),
    Buffer.from([8, 1, 1]),
    Buffer.from([8, 2, 0, 0]),
    Buffer.from([8, 3, 0, 0, 0, 0]),
    Buffer.from([4, 16, 65, 65, 65, 65, 65]),
    Buffer.from([8, 0, 65, 0]),
    Buffer.from([8, 0, 65]),
    Buffer.from([8, 240]),
    Buffer.from([8, 2, 1]),
    Buffer.from([1, 0, 65, 0, 66]),
    Buffer.from([1, 252, 255, 255, 255, 255]),
    Buffer.from([255, 255, 255, 255, 127]),
  ];
  for (const body of malformed) {
    await writeLeveldbFile(join(directory, '001.sst'), tableFile([localRecord(10)], { encode: () => body }));
    await assert.rejects(syntheticExtraction(root), { message: 'Could not safely read Slack desktop LevelDB; quit Slack and try again' });
  }
});

test('rejects table CRC footer handles restart arrays and entry bounds transactionally', async (t) => {
  const { root, directory } = await leveldbDirectory(t);
  const record = localRecord(10);
  const valid = tableFile([record]);
  const raw = entriesBlock([[internalKey(record), record.value]]);
  const corruptCrc = Buffer.from(valid);
  corruptCrc[10] ^= 1;
  const corruptFooter = Buffer.from(valid);
  corruptFooter[valid.length - 1] ^= 1;
  const corruptHandle = Buffer.from(valid);
  corruptHandle[valid.length - 48] = 127;
  const corruptIndexCrc = Buffer.from(valid);
  corruptIndexCrc[valid.length - 49] ^= 1;
  const badRestart = Buffer.from(raw);
  badRestart.writeUInt32LE(1, badRestart.length - 8);
  const badCount = Buffer.from(raw);
  badCount.writeUInt32LE(0xffffffff, badCount.length - 4);
  const badShared = Buffer.from(raw);
  badShared[0] = 1;
  const badValueLength = Buffer.from(raw);
  badValueLength[2] = 127;
  const extra = entriesBlock([[internalKey(record), record.value], [internalKey(localRecord(9)), record.value]]);
  const afterFirst = entriesBlock([[internalKey(record), record.value]]).length - 8;
  extra[afterFirst] = 127;
  const invalidType = localRecord(10, undefined, { type: 2 });
  const unsupportedCompression = Buffer.from(valid);
  const firstSize = raw.length;
  unsupportedCompression[firstSize] = 2;
  unsupportedCompression.writeUInt32LE(maskedCrc(unsupportedCompression.subarray(0, firstSize + 1)), firstSize + 1);
  const cases = [corruptCrc, corruptFooter, corruptHandle, corruptIndexCrc, unsupportedCompression, valid.subarray(0, -20),
    ...[badRestart, badCount, badShared, badValueLength, extra].map((data) => tableFile([record], { data })),
    tableFile([invalidType]), tableFile([{ ...record, type: 0 }]),
    tableFile([record], { data: Buffer.concat([varint(0), varint(32 * 1024 * 1024 + 1), Buffer.alloc(8)]) }),
  ];
  for (const table of cases) {
    await writeLeveldbFile(join(directory, '001.ldb'), table);
    await assert.rejects(syntheticExtraction(root), { message: 'Could not safely read Slack desktop LevelDB; quit Slack and try again' });
  }
});

test('rejects corrupt truncated and misordered WAL records and incomplete write batches', async (t) => {
  const { root, directory } = await leveldbDirectory(t);
  const batch = writeBatch([localRecord(10)]);
  const valid = walFile([batch]);
  const corruptCrc = Buffer.from(valid);
  corruptCrc[10] ^= 1;
  const corruptCount = Buffer.from(batch);
  corruptCount.writeUInt32LE(2, 8);
  const corruptType = Buffer.from(batch);
  corruptType[12] = 7;
  const overflowSequence = Buffer.from(batch);
  overflowSequence.writeBigUInt64LE(1n << 56n, 0);
  const middle = Buffer.from(valid);
  middle[6] = 3;
  middle.writeUInt32LE(maskedCrc(middle.subarray(6)), 0);
  const unfinished = Buffer.from(valid);
  unfinished[6] = 2;
  unfinished.writeUInt32LE(maskedCrc(unfinished.subarray(6)), 0);
  const fragmented = walFile([writeBatch([localRecord(20, undefined, { value: chromiumValue('p'.repeat(100000)) })])]);
  const invalidLaterBatch = walFile([batch, corruptCount]);
  const missingMiddle = Buffer.concat([fragmented.subarray(0, 32768), Buffer.alloc(32768), fragmented.subarray(65536)]);
  const cases = [corruptCrc, valid.subarray(0, -1), middle, unfinished, fragmented.subarray(0, -10), invalidLaterBatch, missingMiddle,
    ...[corruptCount, corruptType, overflowSequence, batch.subarray(0, -1), Buffer.concat([batch, Buffer.from([0])])].map((data) => walFile([data])),
  ];
  for (const log of cases) {
    await writeLeveldbFile(join(directory, '001.log'), log);
    await assert.rejects(syntheticExtraction(root), { message: 'Could not safely read Slack desktop LevelDB; quit Slack and try again' });
  }
});

test('ignores nonnumeric names and symlinks but fails closed on oversized LevelDB files', async (t) => {
  const { root, directory } = await leveldbDirectory(t);
  const ignored = join(directory, 'ignored.sst');
  await writeFile(ignored, tableFile([localRecord(100, 'xoxc-ignored-token')]));
  await symlink(ignored, join(directory, '999.sst'));
  const oversized = await open(join(directory, '998.ldb'), 'w');
  try {
    await oversized.truncate(32 * 1024 * 1024 + 1);
  } finally {
    await oversized.close();
  }
  await writeLeveldbFile(join(directory, '001.ldb'), tableFile([localRecord(1, 'xoxc-bounded-token')]));
  await assert.rejects(syntheticExtraction(root), /Could not safely read Slack desktop LevelDB/);
  await rm(join(directory, '998.ldb'));
  await writeLeveldbManifest(directory);
  assert.deepEqual((await syntheticExtraction(root)).tokens, ['xoxc-bounded-token']);
});

test('bounds cumulative decompression and file counts across LevelDB candidates', async (t) => {
  const { root, directory } = await leveldbDirectory(t);
  const encode = () => Buffer.concat([varint(32 * 1024 * 1024 - 256), Buffer.from([1, 1])]);
  await writeLeveldbFile(join(directory, '999.sst'), tableFile([localRecord(10)], { encode }));
  await writeLeveldbFile(join(directory, '001.sst'), tableFile([localRecord(1, 'xoxc-budget-exhausted')]));
  await assert.rejects(syntheticExtraction(root), /Could not safely read Slack desktop LevelDB/);
  await rm(join(directory, '999.sst'));
  const empty = tableFile([]);
  for (let index = 2; index <= 101; index++) await writeLeveldbFile(join(directory, `${index}.sst`), empty);
  await assert.rejects(syntheticExtraction(root), /Could not safely read Slack desktop LevelDB/);
});

test('incomplete desktop extraction is nonfatal and never needs Keychain without encrypted candidates', async (t) => {
  const root = await temporary(t);
  await writeFile(join(root, 'Cookies'), 'not a database');
  const result = await extractDesktop(root, async () => { throw new Error('Keychain must not be called'); });
  assert.deepEqual(result, { tokens: [], cookies: [] });
  assert.equal(await readFile(join(root, 'Cookies'), 'utf8'), 'not a database');
});

test('recursively removes only empty required arrays from schemas without mutation', () => {
  const schema = { type: 'object', required: [], properties: {
    nested: { required: ['value'], properties: { value: { required: [] } } },
    alternatives: { anyOf: [{ required: [] }, { required: ['id'] }] },
  }, enum: [null, false], other: [] };
  const snapshot = structuredClone(schema);
  assert.deepEqual(sanitizeSchema(schema), { type: 'object', properties: {
    nested: { required: ['value'], properties: { value: {} } },
    alternatives: { anyOf: [{}, { required: ['id'] }] },
  }, enum: [null, false], other: [] });
  assert.deepEqual(schema, snapshot);
});

test('sanitizes tool schemas and removes mutating or unknown tools', () => {
  const message = { jsonrpc: '2.0', id: 1, result: { tools: [{ name: 'channels_list',
    inputSchema: { required: [] }, outputSchema: { items: { required: [] } },
  }, { name: 'conversations_add_message' }, { name: 'conversations_mark' }, { name: 'future_tool' }], required: [] } };
  assert.deepEqual(sanitizeMessage(message).result, { tools: [{ name: 'channels_list', inputSchema: {}, outputSchema: { items: {} } }], required: [] });
  const other = { jsonrpc: '2.0', result: { required: [], content: [{ text: 'unchanged' }] } };
  assert.deepEqual(sanitizeMessage(other), other);
});

test('the Maki request filter forwards only read-only calls and denies write tools', async () => {
  const allowed = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'conversations_history' } });
  const blocked = JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'conversations_add_message' } });
  let rejection;
  let forwarded = '';
  for await (const chunk of Readable.from([Buffer.from(`${allowed}\n${blocked}\n`)]).pipe(createMcpRequestFilter((value) => { rejection = value; }))) forwarded += chunk;
  assert.deepEqual(forwarded.trim().split('\n').map(JSON.parse), [JSON.parse(allowed)]);
  assert.deepEqual(rejection, { jsonrpc: '2.0', id: 2, error: { code: -32000, message: 'Tool blocked by local read-only policy' } });
});

test('request filter rejects batches primitives and invalid JSON-RPC envelopes without forwarding or secret errors', async () => {
  const request = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'conversations_history' } };
  const invalid = [[], [request], [{ ...request, params: { name: 'conversations_add_message' } }], null, false, 7, credentials.xoxc,
    {}, { method: 'initialize' }, { jsonrpc: '1.0', method: 'initialize' }, { ...request, id: null }, { ...request, id: {} },
    { ...request, id: 1.5 }, { ...request, id: Number.MAX_SAFE_INTEGER + 1 }, { ...request, method: null }, { ...request, method: '' },
    { ...request, params: [] }, { ...request, params: null }, { ...request, params: credentials.xoxd },
    { ...request, params: { name: 'conversations_history', arguments: [] } },
    { ...request, params: { name: 'conversations_history', arguments: credentials.xoxd } },
    { ...request, METHOD: 'tools/call' },
    { ...request, params: { name: 'conversations_history', NAME: 'conversations_add_message' } },
    { jsonrpc: '2.0', Method: 'tools/call', Params: { name: 'conversations_add_message' }, id: 1, result: {} },
    { ...request, result: {} }, { ...request, error: {} }, { jsonrpc: '2.0', id: 1 }, { jsonrpc: '2.0', result: {} },
    { jsonrpc: '2.0', id: 1, result: {}, error: { code: -1, message: 'invalid' } },
    { jsonrpc: '2.0', id: 1, error: { code: credentials.xoxc, message: credentials.xoxd } },
  ];
  for (const message of invalid) {
    let forwarded = '';
    let rejections = 0;
    const filter = createMcpRequestFilter(() => { rejections++; });
    filter.on('data', (chunk) => { forwarded += chunk; });
    await assert.rejects(async () => {
      for await (const chunk of Readable.from([`${JSON.stringify(message)}\n`]).pipe(filter)) {}
    }, { message: 'Invalid Maki MCP request' });
    assert.equal(forwarded, '');
    assert.equal(rejections, 0);
  }
});

test('request filter canonicalizes duplicate keys before forwarding to the backend', async () => {
  const wire = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"conversations_add_message","name":"conversations_history","arguments":{"channel":"COLD","channel":"CCURRENT"}}}';
  let output = '';
  for await (const chunk of Readable.from([wire]).pipe(createMcpRequestFilter())) output += chunk;
  assert.equal(output, `${JSON.stringify(JSON.parse(wire))}\n`);
  assert.ok(!output.includes('conversations_add_message'));
  assert.ok(!output.includes('COLD'));
});

test('request filter preserves initialize notifications and responses but drops blocked tool notifications silently', async () => {
  const messages = [
    { jsonrpc: '2.0', id: 0, method: 'initialize', params: {} },
    { jsonrpc: '2.0', method: 'notifications/initialized' },
    { jsonrpc: '2.0', id: 'server-request', result: { roots: [] } },
    { jsonrpc: '2.0', id: 'failed-request', error: { code: -32601, message: 'Unsupported' } },
    ...READ_TOOLS.map((name) => ({ jsonrpc: '2.0', id: name, method: 'tools/call', params: { name } })),
  ];
  const blocked = [
    { jsonrpc: '2.0', method: 'tools/call', params: { name: 'conversations_add_message' } },
    { jsonrpc: '2.0', id: 'unknown', method: 'tools/call', params: { name: 'future_tool' } },
    { jsonrpc: '2.0', id: 'missing', method: 'tools/call' },
  ];
  const rejections = [];
  let output = '';
  for await (const chunk of Readable.from([messages.concat(blocked).map(JSON.stringify).join('\n')]).pipe(createMcpRequestFilter((value) => rejections.push(value)))) output += chunk;
  assert.deepEqual(output.trim().split('\n').map(JSON.parse), messages);
  assert.deepEqual(rejections.map((message) => message.id), ['unknown', 'missing']);
});

test('NDJSON byte limit bounds single chunks split chunks and unterminated messages in both directions', async () => {
  assert.equal(MAX_NDJSON_BYTES, 8 * 1024 * 1024);
  const factories = [
    ['Invalid Maki MCP request', (options) => createMcpRequestFilter(() => {}, options)],
    ['Invalid Slack MCP server output', (options) => createMcpFilter(credentials, options)],
  ];
  const wire = Buffer.from(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { text: 'café' } }));
  const multibyte = wire.indexOf(Buffer.from('é')) + 1;
  for (const [message, create] of factories) {
    for (const chunks of [[wire, Buffer.from('\n')], [wire.subarray(0, multibyte), wire.subarray(multibyte)]]) {
      let output = '';
      for await (const chunk of Readable.from(chunks).pipe(create({ maxLineBytes: wire.length }))) output += chunk;
      assert.deepEqual(JSON.parse(output), JSON.parse(wire));
    }
    let output = '';
    for await (const chunk of Readable.from([Buffer.concat([wire, Buffer.from('\n'), wire, Buffer.from('\n')])]).pipe(create({ maxLineBytes: wire.length }))) output += chunk;
    assert.equal(output.trim().split('\n').length, 2);
    for (const chunks of [[wire], [Buffer.concat([wire, Buffer.from('\n')])], [wire.subarray(0, multibyte), wire.subarray(multibyte)]]) {
      let forwarded = '';
      const filter = create({ maxLineBytes: wire.length - 1 });
      filter.on('data', (chunk) => { forwarded += chunk; });
      await assert.rejects(async () => { for await (const chunk of Readable.from(chunks).pipe(filter)) {} }, { message });
      assert.equal(forwarded, '');
    }
    await assert.rejects(async () => {
      for await (const chunk of Readable.from([Buffer.alloc(MAX_NDJSON_BYTES + 1, 65)]).pipe(create())) {}
    }, { message });
    for (const maxLineBytes of [0, -1, 1.5, Infinity, MAX_NDJSON_BYTES + 1]) {
      assert.throws(() => create({ maxLineBytes }), { message: 'Invalid Slack MCP NDJSON byte limit' });
    }
  }
});

test('the NDJSON filter handles split UTF8, removes empty schema requirements and redacts credentials', async () => {
  const message = { jsonrpc: '2.0', id: 1, result: { tools: [{ name: 'channels_list', description: 'café', inputSchema: { required: [] } }], note: credentials.xoxc } };
  const wire = Buffer.from(`${JSON.stringify(message)}\n`);
  const split = wire.indexOf(Buffer.from('é')) + 1;
  let output = '';
  for await (const chunk of Readable.from([wire.subarray(0, split), wire.subarray(split)]).pipe(createMcpFilter(credentials))) output += chunk;
  const result = JSON.parse(output);
  assert.equal(result.result.tools[0].description, 'café');
  assert.deepEqual(result.result.tools[0].inputSchema, {});
  assert.ok(!output.includes(credentials.xoxc));
});

test('the NDJSON filter does not forward malformed output or disclose it in errors', async () => {
  await assert.rejects(async () => {
    for await (const chunk of Readable.from([`invalid ${credentials.xoxd}\n`]).pipe(createMcpFilter(credentials))) {
      assert.fail('Malformed output was forwarded');
    }
  }, (error) => !error.message.includes(credentials.xoxd));
});

test('redacts object keys, top-level strings and arrays without changing the input', async () => {
  const message = [credentials.xoxc, { [credentials.xoxd]: { [`prefix ${credentials.xoxc}`]: credentials.xoxd } },
    { result: { tools: [{ name: 'channels_list', inputSchema: { required: [] } }, { name: 'conversations_mark' }] } }];
  const snapshot = structuredClone(message);
  const result = sanitizeMessage(message, credentials);
  assert.deepEqual(result, ['[redacted Slack credential]', { '[redacted Slack credential]': {
    'prefix [redacted Slack credential]': '[redacted Slack credential]',
  } }, { result: { tools: [{ name: 'channels_list', inputSchema: {} }] } }]);
  assert.deepEqual(message, snapshot);
  assert.equal(sanitizeMessage(credentials.xoxc, { xoxc: credentials.xoxc, xoxd: '' }), '[redacted Slack credential]');
  assert.equal(sanitizeMessage(credentials.xoxd, { xoxc: '', xoxd: credentials.xoxd }), '[redacted Slack credential]');
  assert.equal(sanitizeMessage('ordinary'), 'ordinary');
  for (const value of [null, false, 4]) assert.equal(sanitizeMessage(value, credentials), value);
  let wire = '';
  for await (const chunk of Readable.from([`${JSON.stringify(message)}\n${JSON.stringify(credentials.xoxc)}`]).pipe(createMcpFilter(credentials))) wire += chunk;
  assert.deepEqual(wire.trimEnd().split('\n').map(JSON.parse), [result, '[redacted Slack credential]']);
});

function serverHarness(t, overrides = {}) {
  const stdin = new PassThrough();
  const stdout = new PassThrough();
  const stderr = new PassThrough();
  const lifecycle = new EventEmitter();
  const child = new EventEmitter();
  child.pid = 987654;
  child.stdin = new PassThrough();
  child.stdout = new PassThrough();
  let output = '';
  let diagnostics = '';
  let input = '';
  const signals = [];
  child.kill = (signal) => { signals.push([child.pid, signal]); return true; };
  stdout.on('data', (chunk) => { output += chunk; });
  stderr.on('data', (chunk) => { diagnostics += chunk; });
  child.stdin.on('data', (chunk) => { input += chunk; });
  const targets = [stdin, stdout, stderr, lifecycle, child, child.stdin, child.stdout];
  const listeners = () => targets.map((target) => target.eventNames().map((event) => [event, target.listenerCount(event)]));
  const baseline = listeners();
  const options = {
    backend, stdin, stdout, stderr, lifecycle, shutdownMs: 50,
    spawn(command, args, settings) {
      assert.equal(command, backend);
      assert.deepEqual(settings.stdio, ['pipe', 'pipe', 'ignore']);
      assert.notEqual(settings.detached, true);
      assert.equal(settings.env.SLACK_MCP_XOXC_TOKEN, credentials.xoxc);
      return child;
    },
    ...overrides,
  };
  const done = runServer(credentials, options);
  t.after(() => {
    for (const stream of [stdin, stdout, stderr, child.stdin, child.stdout]) stream.destroy();
  });
  const close = async (code = 0, signal = null) => {
    child.emit('exit', code, signal);
    child.stdout.end();
    await new Promise((resolve) => setImmediate(resolve));
    child.emit('close', code, signal);
    return done;
  };
  return { stdin, stdout, stderr, lifecycle, child, signals, done, close,
    output: () => output, diagnostics: () => diagnostics, input: () => input,
    clean: () => assert.deepEqual(listeners(), baseline) };
}

test('server close stops open stdin, preserves final output and removes listeners', { timeout: 3000 }, async (t) => {
  const server = serverHarness(t);
  const wire = Buffer.from(JSON.stringify({ result: { text: 'café', [credentials.xoxc]: credentials.xoxd } }));
  const split = wire.indexOf(Buffer.from('é')) + 1;
  server.child.stdout.write(wire.subarray(0, split));
  server.child.stdout.end(wire.subarray(split));
  assert.equal(await server.close(), 0);
  assert.equal(server.lifecycle.exitCode, 0);
  assert.equal(server.stdin.readableEnded, false);
  assert.equal(server.stdin.isPaused(), true);
  assert.equal(server.stdout.writableEnded, false);
  assert.deepEqual(JSON.parse(server.output()), { result: { text: 'café', '[redacted Slack credential]': '[redacted Slack credential]' } });
  assert.equal(server.diagnostics(), '');
  assert.deepEqual(server.signals, []);
  server.stdin.write('{"id":2}\n');
  assert.equal(server.input(), '');
  server.clean();
});

test('stdin EOF flushes a final request and waits for the last response without ending stdout', { timeout: 3000 }, async (t) => {
  const server = serverHarness(t);
  const request = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { name: 'café' } });
  const wire = Buffer.from(request);
  const split = wire.indexOf(Buffer.from('é')) + 1;
  const inputFinished = new Promise((resolve) => server.child.stdin.once('finish', resolve));
  server.stdin.write(wire.subarray(0, split));
  server.stdin.end(wire.subarray(split));
  await inputFinished;
  assert.equal(server.input(), `${request}\n`);
  assert.deepEqual(server.signals, []);
  server.child.stdout.end('{"jsonrpc":"2.0","id":1,"result":"last response"}');
  assert.equal(await server.close(), 0);
  assert.equal(JSON.parse(server.output()).result, 'last response');
  assert.equal(server.stdout.writableEnded, false);
  server.clean();
});

test('last responses drain through stdout backpressure before teardown completes', { timeout: 3000 }, async (t) => {
  let output = '';
  const stdout = new Writable({
    highWaterMark: 1,
    write(chunk, encoding, callback) {
      setTimeout(() => { output += chunk; callback(); }, 5);
    },
  });
  t.after(() => stdout.destroy());
  const server = serverHarness(t, { stdout });
  const message = { result: 'final response '.repeat(10000) };
  server.child.stdout.end(JSON.stringify(message));
  assert.equal(await server.close(), 0);
  assert.deepEqual(JSON.parse(output), message);
  assert.equal(stdout.writableLength, 0);
  assert.equal(stdout.writableEnded, false);
  assert.deepEqual(stdout.eventNames(), []);
  server.clean();
});

test('server lifecycle handles child, stdio and transform errors with fixed diagnostics', { timeout: 5000 }, async (t) => {
  const cases = [
    ['child', 'Could not start Slack MCP server', (server, error) => server.child.emit('error', error)],
    ['child stdin EPIPE', 'Slack MCP server input failed', (server, error) => server.child.stdin.emit('error', error)],
    ['child stdout', 'Slack MCP server output failed', (server, error) => server.child.stdout.emit('error', error)],
    ['wrapper stdin', 'Slack MCP input failed', (server, error) => server.stdin.emit('error', error)],
    ['wrapper stdout', 'Slack MCP output failed', (server, error) => server.stdout.emit('error', error)],
    ['wrapper stdout closes', 'Slack MCP output closed', (server) => server.stdout.emit('close')],
    ['child stdout closes', 'Slack MCP server output closed unexpectedly', (server) => server.child.stdout.destroy()],
    ['diagnostic output', '', (server, error) => server.stderr.emit('error', error)],
    ['requests transform', 'Invalid Maki MCP request', (server) => server.stdin.write(`invalid ${credentials.xoxc}\n`)],
    ['batched requests', 'Invalid Maki MCP request', (server) => server.stdin.write('[{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"conversations_add_message"}}]\n')],
    ['oversized request', 'Invalid Maki MCP request', (server) => server.stdin.write(Buffer.alloc(129, 65))],
    ['oversized response', 'Invalid Slack MCP server output', (server) => server.child.stdout.write(Buffer.alloc(129, 65))],
    ['responses transform', 'Invalid Slack MCP server output', (server) => server.child.stdout.write(`invalid ${credentials.xoxd}\n`)],
  ];
  for (const [name, diagnostic, trigger] of cases) {
    await t.test(name, async (t) => {
      const server = serverHarness(t, { maxLineBytes: 128 });
      trigger(server, Object.assign(new Error(`${credentials.xoxc} ${credentials.xoxd}`), { code: 'EPIPE' }));
      await new Promise((resolve) => setImmediate(resolve));
      assert.equal(server.stdin.isPaused(), true);
      assert.equal(server.diagnostics(), diagnostic ? `${diagnostic}\n` : '');
      assert.deepEqual(server.signals, [[server.child.pid, 'SIGTERM']]);
      assert.equal(await server.close(), 1);
      assert.equal(server.lifecycle.exitCode, 1);
      assert.equal(server.diagnostics().includes(credentials.xoxc), false);
      assert.equal(server.diagnostics().includes(credentials.xoxd), false);
      server.clean();
    });
  }
});

test('server refuses absent or relative backends without spawning a fallback or retaining listeners', { timeout: 3000 }, async (t) => {
  for (const invalid of [undefined, 'slack-mcp-server']) {
    let started = false;
    const server = serverHarness(t, { backend: invalid, spawn() { started = true; } });
    assert.equal(await server.done, 1);
    assert.equal(started, false);
    assert.equal(server.diagnostics(), 'Could not start Slack MCP server\n');
    assert.equal(server.input(), '');
    server.clean();
  }
});

test('synchronous spawn and signal failures never disclose their error details', { timeout: 3000 }, async (t) => {
  const failure = new Error(`${credentials.xoxc} ${credentials.xoxd}`);
  const server = serverHarness(t, { spawn() { throw failure; } });
  assert.equal(await server.done, 1);
  assert.equal(server.diagnostics(), 'Could not start Slack MCP server\n');
  server.clean();
  const denied = serverHarness(t);
  denied.child.kill = () => { throw Object.assign(failure, { code: 'EPERM' }); };
  denied.lifecycle.emit('SIGTERM');
  assert.equal(await denied.close(null, 'SIGTERM'), 143);
  assert.equal(denied.diagnostics(), 'Could not signal Slack MCP server\n');
  denied.clean();
});

test('SIGINT and SIGTERM target the direct child and preserve final responses', { timeout: 3000 }, async (t) => {
  for (const [signal, code] of [['SIGINT', 130], ['SIGTERM', 143]]) {
    const server = serverHarness(t);
    server.lifecycle.emit(signal);
    assert.deepEqual(server.signals, [[server.child.pid, signal]]);
    assert.equal(server.stdin.isPaused(), true);
    server.child.stdout.end('{"result":"shutdown response"}');
    assert.equal(await server.close(null, signal), code);
    assert.equal(JSON.parse(server.output()).result, 'shutdown response');
    assert.deepEqual(server.signals, [[server.child.pid, signal]]);
    assert.equal(server.diagnostics(), '');
    server.clean();
  }
});

test('intentional signals suppress secondary pipe and backend exit diagnostics', { timeout: 3000 }, async (t) => {
  for (const signal of ['SIGINT', 'SIGTERM']) {
    const server = serverHarness(t);
    server.lifecycle.emit(signal);
    server.child.stdin.emit('error', new Error(`${credentials.xoxc} ${credentials.xoxd}`));
    const code = signal === 'SIGINT' ? 130 : 143;
    assert.equal(await server.close(7), code);
    assert.equal(server.diagnostics(), '');
    assert.deepEqual(server.signals, [[server.child.pid, signal]]);
    server.clean();
  }
});

test('EOF deadline escalates an unresponsive direct child without a referenced timer', { timeout: 3000 }, async (t) => {
  const server = serverHarness(t, { shutdownMs: 10 });
  server.stdin.end();
  const limit = Date.now() + 1500;
  while (!server.signals.some(([, signal]) => signal === 'SIGKILL') && Date.now() < limit) {
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  assert.deepEqual(server.signals.slice(0, 2), [[server.child.pid, 'SIGTERM'], [server.child.pid, 'SIGKILL']]);
  assert.equal(server.diagnostics(), 'Slack MCP server shutdown timed out\n');
  assert.equal(await server.close(null, 'SIGKILL'), 1);
  server.clean();
});

async function syntheticWrapper(t, body, onOutput = () => {}) {
  const source = `import { runServer } from ${JSON.stringify(sessionUrl.href)};
    import { spawn } from 'node:child_process';
    await runServer(${JSON.stringify(credentials)}, {
      backend: ${JSON.stringify(backend)},
      spawn: (command, args, options) => spawn(process.execPath, ['--input-type=module', '-e', ${JSON.stringify(body)}], {
        ...options, env: { PATH: process.env.PATH, NODE_NO_WARNINGS: '1' }
      }), shutdownMs: 100
    });`;
  const child = spawn(process.execPath, ['--input-type=module', '-e', source], {
    env: { PATH: process.env.PATH, NODE_NO_WARNINGS: '1' }, stdio: ['pipe', 'pipe', 'pipe'], detached: true,
  });
  let output = '';
  let diagnostics = '';
  child.stdout.on('data', (chunk) => { output += chunk; onOutput(child, output); });
  child.stderr.on('data', (chunk) => { diagnostics += chunk; });
  child.stdin.on('error', () => {});
  const closed = new Promise((resolve) => child.once('close', (code, signal) => resolve({ code, signal })));
  const terminate = () => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} };
  const watchdog = setTimeout(terminate, 3000);
  watchdog.unref();
  t.after(() => { clearTimeout(watchdog); terminate(); });
  await closed;
  clearTimeout(watchdog);
  return { child, output, diagnostics };
}

test('synthetic wrapper exits on child close while its parent keeps stdin open', { timeout: 5000 }, async (t) => {
  const result = await syntheticWrapper(t, 'process.stdout.write(JSON.stringify({ result: "last response" }));');
  assert.equal(result.child.exitCode, 0);
  assert.equal(result.child.signalCode, null);
  assert.equal(result.child.stdin.writableEnded, false);
  assert.equal(JSON.parse(result.output).result, 'last response');
  assert.equal(result.diagnostics, '');
});

test('synthetic wrapper diagnoses nonzero backend exit without echoing stderr or secrets', { timeout: 5000 }, async (t) => {
  const result = await syntheticWrapper(t, `process.stderr.write(${JSON.stringify(`${credentials.xoxc} ${credentials.xoxd}\n`)}); process.exitCode = 7;`);
  assert.equal(result.child.exitCode, 7);
  assert.equal(result.output, '');
  assert.equal(result.diagnostics, 'Slack MCP backend exited before completing; verify Slack is signed in, run auth again, and retry\n');
});

test('synthetic newline-only backend receives the final unterminated request at EOF', { timeout: 5000 }, async (t) => {
  const request = { jsonrpc: '2.0', id: 1, method: 'initialize', params: { name: 'café' } };
  const body = `let buffer = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => {
      buffer += chunk;
      let end;
      while ((end = buffer.indexOf('\\n')) !== -1) {
        const request = JSON.parse(buffer.slice(0, end));
        buffer = buffer.slice(end + 1);
        process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result: request.params.name }) + '\\n');
      }
    });
    process.stdout.write(JSON.stringify({ ready: true }) + '\\n');`;
  let sent = false;
  const result = await syntheticWrapper(t, body, (wrapper, output) => {
    if (sent || !output.includes('\n')) return;
    sent = true;
    wrapper.stdin.end(JSON.stringify(request));
  });
  assert.equal(result.child.exitCode, 0);
  assert.equal(result.diagnostics, '');
  assert.deepEqual(result.output.trimEnd().split('\n').map(JSON.parse), [{ ready: true }, { jsonrpc: '2.0', id: 1, result: 'café' }]);
});

test('native signals reach the direct backend and escalate only if graceful shutdown is ignored', { timeout: 8000 }, async (t) => {
  for (const [signal, code] of [['SIGINT', 130], ['SIGTERM', 143]]) {
    for (const ignore of [false, true]) {
      await t.test(`${signal} ${ignore ? 'escalation' : 'graceful'}`, async (t) => {
        let ready;
        const body = `for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => {
            if (!${ignore}) process.stdout.write(JSON.stringify({ signal }) + '\\n', () => process.exit(0));
          });
          setInterval(() => {}, 1000);
          process.stdout.write(JSON.stringify({ pid: process.pid }) + '\\n');`;
        t.after(() => { if (ready) { try { process.kill(ready.pid, 'SIGKILL'); } catch {} } });
        const result = await syntheticWrapper(t, body, (wrapper, output) => {
          if (ready || !output.includes('\n')) return;
          ready = JSON.parse(output.split('\n')[0]);
          wrapper.kill(signal);
        });
        assert.ok(ready);
        assert.equal(result.child.exitCode, code);
        assert.equal(result.child.signalCode, null);
        assert.equal(result.diagnostics, '');
        if (!ignore) assert.deepEqual(JSON.parse(result.output.trim().split('\n').at(-1)), { signal });
        assert.throws(() => process.kill(ready.pid, 0), { code: 'ESRCH' });
      });
    }
  }
});

test('Maki-style SIGKILL of the wrapper process group terminates a backend that never reads stdin', { timeout: 5000 }, async (t) => {
  let ready;
  const body = `process.on('SIGINT', () => {});
    process.on('SIGTERM', () => {});
    setInterval(() => {}, 1000);
    process.stdout.write(JSON.stringify({ pid: process.pid }) + '\\n');`;
  t.after(() => { if (ready) { try { process.kill(ready.pid, 'SIGKILL'); } catch {} } });
  const result = await syntheticWrapper(t, body, (wrapper, output) => {
    if (ready || !output.includes('\n')) return;
    ready = JSON.parse(output.split('\n')[0]);
    process.kill(-wrapper.pid, 'SIGKILL');
  });
  assert.ok(ready);
  assert.equal(result.child.exitCode, null);
  assert.equal(result.child.signalCode, 'SIGKILL');
  assert.equal(result.child.stdin.writableEnded, false);
  assert.equal(result.diagnostics, '');
  const running = async () => {
    try {
      process.kill(ready.pid, 0);
      if (process.platform !== 'linux') return true;
      const state = await readFile(`/proc/${ready.pid}/stat`, 'utf8');
      return state.slice(state.lastIndexOf(')') + 2, state.lastIndexOf(')') + 3) !== 'Z';
    } catch (error) {
      if (error.code === 'ESRCH' || error.code === 'ENOENT') return false;
      throw error;
    }
  };
  const limit = Date.now() + 1000;
  while (await running() && Date.now() < limit) await new Promise((resolve) => setTimeout(resolve, 5));
  assert.equal(await running(), false);
});

test('shutdown timers alone do not keep a synthetic wrapper alive', { timeout: 5000 }, async (t) => {
  const body = `import { runServer } from ${JSON.stringify(sessionUrl.href)};
    import { EventEmitter } from 'node:events';
    import { PassThrough } from 'node:stream';
    const lifecycle = new EventEmitter();
    runServer(${JSON.stringify(credentials)}, {
      backend: ${JSON.stringify(backend)},
      lifecycle, shutdownMs: 1000,
      spawn() { return Object.assign(new EventEmitter(), {
        pid: 987654, stdin: new PassThrough(), stdout: new PassThrough(),
        kill(signal) { if (signal === 'SIGKILL') process.stdout.write('timer kept wrapper alive'); }
      }); }
    });
    lifecycle.emit('SIGTERM');`;
  const result = await syntheticWrapper(t, body);
  assert.equal(result.child.exitCode, 0);
  assert.equal(result.output, '');
  assert.equal(result.diagnostics, '');
});

test('synthetic child stdin EPIPE cannot crash or disclose secrets', { timeout: 5000 }, async (t) => {
  const source = `import { runServer } from ${JSON.stringify(sessionUrl.href)};
    import { spawn } from 'node:child_process';
    await runServer(${JSON.stringify(credentials)}, {
      backend: ${JSON.stringify(backend)},
      spawn: (command, args, options) => {
        const child = spawn(process.execPath, ['-e', 'process.stdin.destroy(); setInterval(() => {}, 1000);'], options);
        child.once('spawn', () => setTimeout(() => {
          child.stdin.destroy(Object.assign(new Error(${JSON.stringify(credentials.xoxc)}), { code: 'EPIPE' }));
        }, 20));
        return child;
      }, shutdownMs: 100
    });`;
  const wrapper = spawn(process.execPath, ['--input-type=module', '-e', source], {
    env: { PATH: process.env.PATH, NODE_NO_WARNINGS: '1' }, stdio: ['pipe', 'pipe', 'pipe'],
  });
  let diagnostics = '';
  wrapper.stderr.on('data', (chunk) => { diagnostics += chunk; });
  wrapper.stdout.resume();
  const watchdog = setTimeout(() => wrapper.kill('SIGKILL'), 3000);
  watchdog.unref();
  t.after(() => { clearTimeout(watchdog); wrapper.kill('SIGKILL'); });
  const code = await new Promise((resolve) => wrapper.once('close', resolve));
  clearTimeout(watchdog);
  assert.equal(code, 1);
  assert.equal(diagnostics, 'Slack MCP server input failed\n');
});
