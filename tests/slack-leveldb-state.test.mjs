import assert from 'node:assert/strict';
import test from 'node:test';
import fs, { appendFile, lstat, mkdtemp, readFile, rename, rm, symlink, utimes, writeFile } from 'node:fs/promises';
import { syncBuiltinESMExports } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { extractLeveldbTokens } from '../modules/features/ai/slack-mcp/leveldb.mjs';

const refusal = { message: 'Could not safely read Slack desktop LevelDB; quit Slack and try again' };
const currentName = 'MANIFEST-000001';
const defaultKey = Buffer.from('_https://app.slack.com\0\x01localConfig_v2');

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

function slice(value) {
  return Buffer.concat([varint(value.length), value]);
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

function walFile(records) {
  const chunks = [];
  let offset = 0;
  for (const record of records) {
    let position = 0;
    let first = true;
    do {
      let remaining = 32768 - offset % 32768;
      if (remaining < 7) {
        chunks.push(Buffer.alloc(remaining));
        offset += remaining;
        remaining = 32768;
      }
      const length = Math.min(record.length - position, remaining - 7);
      const last = position + length === record.length;
      const body = Buffer.concat([Buffer.from([first ? (last ? 1 : 2) : (last ? 4 : 3)]), record.subarray(position, position + length)]);
      chunks.push(uint32(maskedCrc(body)), Buffer.from([length & 255, length >>> 8]), body);
      offset += length + 7;
      position += length;
      first = false;
    } while (position < record.length);
  }
  return Buffer.concat(chunks);
}

function localRecord(sequence, token = 'xoxc-synthetic-current', { type = 1, key = defaultKey } = {}) {
  return { sequence: BigInt(sequence), type, key,
    value: type === 0 ? Buffer.alloc(0) : Buffer.concat([Buffer.from([1]), Buffer.from(JSON.stringify({ teams: { TSYNTH: { token } } }))]),
  };
}

function internalKey(record) {
  const trailer = Buffer.alloc(8);
  trailer.writeBigUInt64LE((record.sequence << 8n) | BigInt(record.type));
  return Buffer.concat([record.key, trailer]);
}

function writeBatch(records) {
  const header = Buffer.alloc(12);
  header.writeBigUInt64LE(records[0]?.sequence ?? 0n);
  header.writeUInt32LE(records.length, 8);
  return Buffer.concat([header, ...records.flatMap((record) => [Buffer.from([record.type]), slice(record.key), ...(record.type === 1 ? [slice(record.value)] : [])])]);
}

function entriesBlock(entries) {
  const chunks = [];
  const restarts = [];
  let offset = 0;
  for (const [key, value] of entries) {
    restarts.push(offset);
    const entry = Buffer.concat([varint(0), varint(key.length), varint(value.length), key, value]);
    chunks.push(entry);
    offset += entry.length;
  }
  if (restarts.length === 0) restarts.push(0);
  return Buffer.concat([...chunks, ...restarts.map(uint32), uint32(restarts.length)]);
}

function storedBlock(buffer) {
  const body = Buffer.concat([buffer, Buffer.from([0])]);
  return Buffer.concat([body, uint32(maskedCrc(body))]);
}

function tableFile(records) {
  const sorted = [...records].sort((left, right) => Buffer.compare(left.key, right.key) || (left.sequence > right.sequence ? -1 : left.sequence < right.sequence ? 1 : right.type - left.type));
  const entries = sorted.map((record) => [internalKey(record), record.value]);
  const data = storedBlock(entriesBlock(entries));
  const meta = storedBlock(entriesBlock([]));
  const index = storedBlock(entriesBlock([[entries.at(-1)[0], Buffer.concat([varint(0), varint(data.length - 5)])]]));
  const footer = Buffer.alloc(48);
  Buffer.concat([varint(data.length), varint(meta.length - 5), varint(data.length + meta.length), varint(index.length - 5)]).copy(footer);
  footer.writeBigUInt64LE(0xdb4775248b80fb57n, 40);
  return Buffer.concat([data, meta, index, footer]);
}

function tableFixture(number, records, extension = 'ldb', level = 0) {
  return { number, records, level, name: `${number}.${extension}`, buffer: tableFile(records) };
}

function newFile(file) {
  const keys = file.records.map(internalKey);
  return Buffer.concat([varint(7), varint(file.level), varint(file.number), varint(file.buffer.length), slice(keys[0]), slice(keys.at(-1))]);
}

function deleteFile(number, level = 0) {
  return Buffer.concat([varint(6), varint(level), varint(number)]);
}

function manifestHeader({ logNumber = 0, previousLogNumber, nextFileNumber = 1000, lastSequence = 1000 } = {}) {
  const fields = [varint(1), slice(Buffer.from('leveldb.BytewiseComparator')), varint(2), varint(logNumber), varint(3), varint(nextFileNumber), varint(4), varint(lastSequence)];
  if (previousLogNumber !== undefined) fields.push(varint(9), varint(previousLogNumber));
  return Buffer.concat(fields);
}

async function temporary(t) {
  const directory = await mkdtemp(join(tmpdir(), 'slack-leveldb-state-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}

async function installState(directory, { files = [], edits, ...header } = {}) {
  for (const file of files) await writeFile(join(directory, file.name), file.buffer);
  await writeFile(join(directory, currentName), walFile(edits ?? [Buffer.concat([manifestHeader(header), ...files.map(newFile)])]));
  await writeFile(join(directory, 'CURRENT'), `${currentName}\n`);
}

async function readWithMutation(t, directory, trigger, mutate, occurrence = 1) {
  const original = fs.open;
  let opens = 0;
  let mutations = 0;
  let completed = false;
  t.mock.method(fs, 'open', async (path, ...args) => {
    if (path === join(directory, trigger) && ++opens === occurrence) {
      mutations++;
      await mutate();
      completed = true;
    }
    return original(path, ...args);
  });
  syncBuiltinESMExports();
  try {
    await assert.rejects(extractLeveldbTokens(directory), refusal);
    assert.equal(mutations, 1);
    assert.equal(completed, true);
  } finally {
    t.mock.restoreAll();
    syncBuiltinESMExports();
  }
}

test('selects only manifest live tables and ignores obsolete orphan high-sequence records', async (t) => {
  const directory = await temporary(t);
  const current = tableFixture(10, [localRecord(20)]);
  const obsolete = tableFixture(9, [localRecord(999, 'xoxc-synthetic-obsolete')], 'sst');
  const orphan = tableFixture(999, [localRecord(10000, 'xoxc-synthetic-orphan')]);
  await installState(directory, { files: [current, obsolete, orphan], edits: [
    Buffer.concat([manifestHeader(), newFile(obsolete)]),
    Buffer.concat([deleteFile(obsolete.number), newFile(current)]),
  ] });
  await writeFile(join(directory, '1001.ldb'), 'invalid orphan table');
  await writeFile(join(directory, 'MANIFEST-999999'), walFile([Buffer.concat([manifestHeader(), newFile(orphan)])]));
  assert.deepEqual(await extractLeveldbTokens(directory), ['xoxc-synthetic-current']);
});

test('does not resurrect obsolete values after compaction drops a tombstone', async (t) => {
  const directory = await temporary(t);
  const old = tableFixture(10, [localRecord(10, 'xoxc-synthetic-deleted')]);
  const deleted = tableFixture(11, [localRecord(20, undefined, { type: 0 })]);
  const unrelated = tableFixture(12, [localRecord(30, 'xoxc-synthetic-unrelated', { key: Buffer.from('other-key') })]);
  await installState(directory, { files: [old, deleted, unrelated], logNumber: 30, edits: [
    Buffer.concat([manifestHeader({ logNumber: 30 }), newFile(old), newFile(deleted)]),
    Buffer.concat([deleteFile(10), deleteFile(11), newFile(unrelated)]),
  ] });
  await writeFile(join(directory, '5.log'), walFile([writeBatch([localRecord(100, 'xoxc-synthetic-old-wal')])]));
  await writeFile(join(directory, '30.log'), Buffer.alloc(0));
  assert.deepEqual(await extractLeveldbTokens(directory), []);
});

test('a deleted table tombstone cannot suppress a live value', async (t) => {
  const directory = await temporary(t);
  const stale = tableFixture(10, [localRecord(100, undefined, { type: 0 })]);
  const live = tableFixture(11, [localRecord(20)]);
  await installState(directory, { files: [stale, live], edits: [
    Buffer.concat([manifestHeader(), newFile(stale)]),
    Buffer.concat([deleteFile(10), newFile(live)]),
  ] });
  assert.deepEqual(await extractLeveldbTokens(directory), ['xoxc-synthetic-current']);
});

test('replays current previous and unregistered newer logs, not obsolete logs', async (t) => {
  const directory = await temporary(t);
  await installState(directory, { logNumber: 20, previousLogNumber: 8, nextFileNumber: 21 });
  await writeFile(join(directory, '7.log'), walFile([writeBatch([localRecord(999, 'xoxc-synthetic-obsolete')])]));
  await writeFile(join(directory, '8.log'), walFile([writeBatch([localRecord(40, 'xoxc-synthetic-previous')])]));
  await writeFile(join(directory, '20.log'), walFile([writeBatch([localRecord(20, 'xoxc-synthetic-log')])]));
  await writeFile(join(directory, '25.log'), walFile([writeBatch([localRecord(30, 'xoxc-synthetic-newer')])]));
  assert.deepEqual(await extractLeveldbTokens(directory), ['xoxc-synthetic-previous']);
  await writeFile(join(directory, '25.log'), walFile([writeBatch([localRecord(41, 'xoxc-synthetic-newer')])]));
  assert.deepEqual(await extractLeveldbTokens(directory), ['xoxc-synthetic-newer']);
  await writeFile(join(directory, '25.log'), walFile([writeBatch([localRecord(42, undefined, { type: 0 })])]));
  assert.deepEqual(await extractLeveldbTokens(directory), []);
  await writeFile(join(directory, '25.log'), Buffer.from('incomplete active log'));
  await assert.rejects(extractLeveldbTokens(directory), refusal);
});

test('handles uint64 file numbers without rounding or limiting newer logs to next-file', async (t) => {
  const directory = await temporary(t);
  const number = (1n << 63n) + 7n;
  const live = tableFixture(number, [localRecord(10)]);
  await installState(directory, { files: [live], logNumber: number + 1n, nextFileNumber: number + 2n });
  await writeFile(join(directory, `${number + 1n}.log`), Buffer.alloc(0));
  await writeFile(join(directory, `${number + 3n}.log`), walFile([writeBatch([localRecord(20, 'xoxc-synthetic-uint64')])]));
  assert.deepEqual(await extractLeveldbTokens(directory), ['xoxc-synthetic-uint64']);
});

test('applies per-edit deletions before additions for a trivial table level move', async (t) => {
  const directory = await temporary(t);
  const live = tableFixture(10, [localRecord(10)]);
  await installState(directory, { files: [live], edits: [
    Buffer.concat([manifestHeader(), newFile(live)]),
    Buffer.concat([newFile({ ...live, level: 1 }), deleteFile(10)]),
    deleteFile(10),
  ] });
  assert.deepEqual(await extractLeveldbTokens(directory), ['xoxc-synthetic-current']);
});

test('uses CRC-checked fragmented WAL records for manifests as well as write batches', async (t) => {
  const directory = await temporary(t);
  const live = tableFixture(10, [localRecord(10)]);
  const pointer = Buffer.concat([varint(5), varint(0), slice(Buffer.concat([Buffer.alloc(100000, 65), Buffer.alloc(8)]))]);
  await installState(directory, { files: [live], edits: [Buffer.concat([manifestHeader(), pointer, newFile(live)])] });
  assert.deepEqual(await extractLeveldbTokens(directory), ['xoxc-synthetic-current']);
  const path = join(directory, currentName);
  const manifest = await readFile(path);
  for (const bad of [manifest.subarray(0, -1), Buffer.from(manifest)]) {
    if (bad.length === manifest.length) bad[40000] ^= 1;
    await writeFile(path, bad);
    await assert.rejects(extractLeveldbTokens(directory), refusal);
  }
});

test('requires a valid CURRENT and its named manifest even if token files are readable', async (t) => {
  const directory = await temporary(t);
  const live = tableFixture(10, [localRecord(10)]);
  await writeFile(join(directory, live.name), live.buffer);
  await assert.rejects(extractLeveldbTokens(directory), refusal);
  await writeFile(join(directory, 'CURRENT'), `${currentName}\n`);
  await assert.rejects(extractLeveldbTokens(directory), refusal);
  await installState(directory, { files: [live] });
  for (const invalid of [currentName, `../${currentName}\n`, `${currentName}\n\n`, `${currentName}\nextra`, 'MANIFEST-18446744073709551616\n']) {
    await writeFile(join(directory, 'CURRENT'), invalid);
    await assert.rejects(extractLeveldbTokens(directory), refusal);
  }
});

test('allows an absent store and a valid empty store but refuses an uninitialized directory', async (t) => {
  const directory = await temporary(t);
  assert.deepEqual(await extractLeveldbTokens(join(directory, 'absent')), []);
  await assert.rejects(extractLeveldbTokens(directory), refusal);
  await installState(directory);
  assert.deepEqual(await extractLeveldbTokens(directory), []);
});

test('rejects incomplete version metadata unknown tags and invalid file metadata', async (t) => {
  const directory = await temporary(t);
  const live = tableFixture(10, [localRecord(10)]);
  await installState(directory, { files: [live] });
  const invalid = [
    Buffer.concat([varint(2), varint(0), varint(3), varint(20)]),
    Buffer.concat([varint(3), varint(20), varint(4), varint(0)]),
    Buffer.concat([manifestHeader(), varint(8)]),
    Buffer.concat([manifestHeader(), varint(1), slice(Buffer.from('unknown.Comparator'))]),
    Buffer.concat([manifestHeader(), varint(4), varint(1n << 56n)]),
    Buffer.concat([manifestHeader(), varint(2), varint(1n << 64n)]),
    Buffer.concat([manifestHeader(), newFile({ ...live, level: 7 })]),
    Buffer.concat([manifestHeader(), newFile({ ...live, buffer: Buffer.alloc(0) })]),
    Buffer.concat([manifestHeader(), newFile(live), newFile(live)]),
    Buffer.concat([manifestHeader(), newFile(live), Buffer.from([128])]),
  ];
  for (const edit of invalid) {
    await writeFile(join(directory, currentName), walFile([edit]));
    await assert.rejects(extractLeveldbTokens(directory), refusal);
  }
});

test('requires live tables and advertised logs and refuses ambiguous duplicate table names', async (t) => {
  const directory = await temporary(t);
  const live = tableFixture(10, [localRecord(10)]);
  await installState(directory, { files: [live] });
  await writeFile(join(directory, '10.sst'), live.buffer);
  await assert.rejects(extractLeveldbTokens(directory), refusal);
  await rm(join(directory, '10.sst'));
  await writeFile(join(directory, live.name), live.buffer.subarray(0, -1));
  await assert.rejects(extractLeveldbTokens(directory), refusal);
  await rm(join(directory, live.name));
  await assert.rejects(extractLeveldbTokens(directory), refusal);
  await installState(directory, { logNumber: 20 });
  await assert.rejects(extractLeveldbTokens(directory), refusal);
  await writeFile(join(directory, '20.log'), Buffer.alloc(0));
  await installState(directory, { logNumber: 20, previousLogNumber: 8 });
  await assert.rejects(extractLeveldbTokens(directory), refusal);
});

test('does not follow symlinked CURRENT manifests live tables or active logs', async (t) => {
  for (const target of ['CURRENT', currentName, '10.ldb', '20.log']) {
    await t.test(target, async (t) => {
      const directory = await temporary(t);
      await installState(directory, { files: [tableFixture(10, [localRecord(10)])], logNumber: 20 });
      await writeFile(join(directory, '20.log'), Buffer.alloc(0));
      const path = join(directory, target);
      await rename(path, join(directory, 'synthetic-target'));
      await symlink(join(directory, 'synthetic-target'), path);
      await assert.rejects(extractLeveldbTokens(directory), refusal);
    });
  }
});

test('bounds manifest reads and selected file counts', async (t) => {
  const directory = await temporary(t);
  await installState(directory);
  const manifest = await fs.open(join(directory, currentName), 'r+');
  try {
    await manifest.truncate(32 * 1024 * 1024 + 1);
  } finally {
    await manifest.close();
  }
  await assert.rejects(extractLeveldbTokens(directory), refusal);
  await installState(directory, { logNumber: 1 });
  for (let number = 1; number <= 101; number++) await writeFile(join(directory, `${number}.log`), Buffer.alloc(0));
  await assert.rejects(extractLeveldbTokens(directory), refusal);
});

test('revalidates an earlier file after another file has been read', async (t) => {
  for (const mutation of ['same-size table', 'growing log', 'replacement inode']) {
    await t.test(mutation, async (t) => {
      const directory = await temporary(t);
      const early = tableFixture(10, [localRecord(10, 'xoxc-synthetic-before')]);
      const late = tableFixture(20, [localRecord(20, undefined, { key: Buffer.from('other-key') })]);
      await installState(directory, { files: [early, late], logNumber: mutation === 'growing log' ? 8 : 0 });
      const path = join(directory, mutation === 'growing log' ? '8.log' : early.name);
      if (mutation === 'growing log') await writeFile(path, Buffer.alloc(0));
      await readWithMutation(t, directory, late.name, async () => {
        if (mutation === 'growing log') await appendFile(path, walFile([writeBatch([localRecord(30, undefined, { type: 0 })])]));
        else if (mutation === 'replacement inode') {
          await writeFile(join(directory, 'replacement'), early.buffer);
          await rename(join(directory, 'replacement'), path);
        } else {
          const metadata = await lstat(path);
          const changed = tableFile([localRecord(10, 'xoxc-synthetic-afterx')]);
          assert.equal(changed.length, early.buffer.length);
          await writeFile(path, changed);
          await utimes(path, metadata.atime, metadata.mtime);
        }
      });
    });
  }
});

test('refuses a manifest append or CURRENT switch after it has been read', async (t) => {
  for (const target of ['manifest', 'CURRENT']) {
    await t.test(target, async (t) => {
      const directory = await temporary(t);
      const live = tableFixture(10, [localRecord(10)]);
      await installState(directory, { files: [live] });
      await writeFile(join(directory, 'MANIFEST-000002'), walFile([manifestHeader()]));
      await readWithMutation(t, directory, live.name, async () => {
        if (target === 'manifest') await appendFile(join(directory, currentName), walFile([deleteFile(10)]));
        else await writeFile(join(directory, 'CURRENT'), 'MANIFEST-000002\n');
      });
    });
  }
});

test('compares CURRENT contents again after final metadata validation', async (t) => {
  const directory = await temporary(t);
  await installState(directory, { files: [tableFixture(10, [localRecord(10)])] });
  await writeFile(join(directory, 'MANIFEST-000002'), walFile([manifestHeader()]));
  await readWithMutation(t, directory, 'CURRENT', () => writeFile(join(directory, 'CURRENT'), 'MANIFEST-000002\n'), 2);
});

test('refuses a new recovery-eligible log discovered at final membership validation', async (t) => {
  const directory = await temporary(t);
  const live = tableFixture(10, [localRecord(10)]);
  await installState(directory, { files: [live], logNumber: 8 });
  await writeFile(join(directory, '8.log'), Buffer.alloc(0));
  await readWithMutation(t, directory, live.name, () => writeFile(join(directory, '11.log'), walFile([writeBatch([localRecord(20, undefined, { type: 0 })])])));
});
