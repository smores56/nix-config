import { constants } from 'node:fs';
import { lstat, open, readdir } from 'node:fs/promises';
import { join } from 'node:path';

const TOKEN_PATTERN = /^xoxc-[A-Za-z0-9-]{6,}$/;
const MAX_LEVELDB_FILES = 100;
const MAX_LEVELDB_BYTES = 32 * 1024 * 1024;
const MAX_LEVELDB_SEQUENCE = (1n << 56n) - 1n;
const MAX_LEVELDB_FILE_NUMBER = (1n << 64n) - 1n;
const LEVELDB_LOG_BLOCK_BYTES = 32768;
const CRC32C_TABLE = Uint32Array.from({ length: 256 }, (_, value) => {
  for (let bit = 0; bit < 8; bit++) value = (value >>> 1) ^ ((value & 1) ? 0x82f63b78 : 0);
  return value >>> 0;
});

function requireLeveldb(condition) {
  if (!condition) throw new Error('Invalid Slack desktop LevelDB data');
}

function spendLeveldb(budget, bytes) {
  requireLeveldb(Number.isSafeInteger(bytes) && bytes >= 0 && bytes <= budget.remaining);
  budget.remaining -= bytes;
}

function chromiumString(buffer) {
  requireLeveldb(Buffer.isBuffer(buffer) && buffer.length > 0 && buffer.length <= MAX_LEVELDB_BYTES);
  requireLeveldb(buffer[0] === 1 || (buffer[0] === 0 && buffer.length % 2 === 1));
  return buffer.toString(buffer[0] === 0 ? 'utf16le' : 'latin1', 1);
}

export function extractTokens(buffer) {
  try {
    const config = JSON.parse(chromiumString(buffer));
    if (!config || typeof config !== 'object' || !config.teams || typeof config.teams !== 'object') return [];
    return [...new Set(Object.values(config.teams)
      .map((team) => team?.token)
      .filter((token) => typeof token === 'string' && token === token.trim() && TOKEN_PATTERN.test(token)))];
  } catch {
    return [];
  }
}

function leveldbVarint(buffer, cursor) {
  let value = 0;
  for (let shift = 0; shift <= 28; shift += 7) {
    requireLeveldb(cursor.offset < cursor.end);
    const byte = buffer[cursor.offset++];
    value += (byte & 127) * 2 ** shift;
    requireLeveldb(value <= MAX_LEVELDB_BYTES);
    if (byte < 128) return value;
  }
  requireLeveldb(false);
}

function leveldbUint64(buffer, cursor) {
  let value = 0n;
  for (let shift = 0n; shift < 64n; shift += 7n) {
    requireLeveldb(cursor.offset < cursor.end);
    const byte = buffer[cursor.offset++];
    value |= BigInt(byte & 127) << shift;
    requireLeveldb(value <= MAX_LEVELDB_FILE_NUMBER);
    if (byte < 128) return value;
  }
  requireLeveldb(false);
}

function leveldbSlice(buffer, cursor) {
  const length = leveldbVarint(buffer, cursor);
  requireLeveldb(length <= cursor.end - cursor.offset);
  const value = buffer.subarray(cursor.offset, cursor.offset + length);
  cursor.offset += length;
  return value;
}

function maskedCrc32c(buffer, start, end) {
  let crc = 0xffffffff;
  for (let offset = start; offset < end; offset++) crc = CRC32C_TABLE[(crc ^ buffer[offset]) & 255] ^ (crc >>> 8);
  crc = ~crc >>> 0;
  return (((crc >>> 15) | (crc << 17)) + 0xa282ead8) >>> 0;
}

function rawSnappy(buffer, budget) {
  const cursor = { offset: 0, end: buffer.length };
  const size = leveldbVarint(buffer, cursor);
  spendLeveldb(budget, size);
  const output = Buffer.alloc(size);
  let written = 0;
  while (cursor.offset < cursor.end) {
    const tag = buffer[cursor.offset++];
    const kind = tag & 3;
    if (kind === 0) {
      let length = (tag >>> 2) + 1;
      if (length > 60) {
        const bytes = length - 60;
        requireLeveldb(bytes <= cursor.end - cursor.offset);
        length = buffer.readUIntLE(cursor.offset, bytes) + 1;
        cursor.offset += bytes;
      }
      requireLeveldb(length <= cursor.end - cursor.offset && length <= size - written);
      buffer.copy(output, written, cursor.offset, cursor.offset + length);
      cursor.offset += length;
      written += length;
    } else {
      const bytes = kind === 1 ? 1 : kind === 2 ? 2 : 4;
      requireLeveldb(bytes <= cursor.end - cursor.offset);
      const distance = kind === 1 ? ((tag & 224) << 3) | buffer[cursor.offset] : buffer.readUIntLE(cursor.offset, bytes);
      const length = kind === 1 ? 4 + ((tag >>> 2) & 7) : 1 + (tag >>> 2);
      cursor.offset += bytes;
      requireLeveldb(distance > 0 && distance <= written && length <= size - written);
      for (let index = 0; index < length; index++) {
        output[written] = output[written - distance];
        written++;
      }
    }
  }
  requireLeveldb(written === size);
  return output;
}

function blockHandle(buffer, cursor) {
  return { offset: leveldbVarint(buffer, cursor), size: leveldbVarint(buffer, cursor) };
}

function tableBlock(buffer, handle, limit, budget) {
  const end = handle.offset + handle.size;
  requireLeveldb(end + 5 <= limit);
  const compression = buffer[end];
  requireLeveldb((compression === 0 || compression === 1) && buffer.readUInt32LE(end + 1) === maskedCrc32c(buffer, handle.offset, end + 1));
  const data = buffer.subarray(handle.offset, end);
  if (compression === 1) return rawSnappy(data, budget);
  spendLeveldb(budget, data.length);
  return data;
}

function* blockEntries(buffer, budget) {
  requireLeveldb(buffer.length >= 8);
  const count = buffer.readUInt32LE(buffer.length - 4);
  requireLeveldb(count > 0 && count <= Math.floor((buffer.length - 4) / 4));
  const end = buffer.length - 4 - count * 4;
  let previousRestart = -1;
  for (let index = 0; index < count; index++) {
    const restart = buffer.readUInt32LE(end + index * 4);
    requireLeveldb((index === 0 ? restart === 0 : restart > previousRestart) && (restart < end || (end === 0 && count === 1)));
    previousRestart = restart;
  }
  const cursor = { offset: 0, end };
  let previous = Buffer.alloc(0);
  let restartIndex = 0;
  while (cursor.offset < end) {
    const start = cursor.offset;
    const restart = restartIndex < count ? buffer.readUInt32LE(end + restartIndex * 4) : end;
    requireLeveldb(restart >= start);
    const shared = leveldbVarint(buffer, cursor);
    const nonshared = leveldbVarint(buffer, cursor);
    const length = leveldbVarint(buffer, cursor);
    requireLeveldb(shared <= previous.length && nonshared + length <= end - cursor.offset);
    if (restart === start) {
      requireLeveldb(shared === 0);
      restartIndex++;
    }
    spendLeveldb(budget, shared + nonshared);
    const key = Buffer.concat([previous.subarray(0, shared), buffer.subarray(cursor.offset, cursor.offset + nonshared)]);
    cursor.offset += nonshared;
    const value = buffer.subarray(cursor.offset, cursor.offset + length);
    cursor.offset += length;
    previous = key;
    yield [key, value];
  }
  requireLeveldb(restartIndex === count || (end === 0 && count === 1));
}

function localConfigOrigin(key) {
  const separator = key.indexOf(0);
  if (separator < 1 || separator > 2048) return null;
  const origin = key.toString('latin1', 0, separator);
  if (origin !== origin.trim() || !/^_https:\/\/(?:[a-z0-9-]+\.)*slack\.com$/i.test(origin)) return null;
  const name = key.subarray(separator + 1);
  if (!((name[0] === 1 && name.length === 15) || (name[0] === 0 && name.length === 29))) return null;
  return chromiumString(name) === 'localConfig_v2' ? origin.toLowerCase() : null;
}

function mergeRecord(records, origin, record) {
  const previous = records.get(origin);
  if (!previous || record.sequence > previous.sequence) records.set(origin, record);
  else if (record.sequence === previous.sequence && (record.type !== previous.type || (record.type === 1 && !record.value.equals(previous.value)))) {
    records.set(origin, { sequence: record.sequence, type: 0, value: null });
  }
}

function rememberRecord(records, key, sequence, type, value, budget) {
  const origin = localConfigOrigin(key);
  if (!origin || (records.has(origin) && sequence < records.get(origin).sequence)) return;
  if (type === 1) {
    spendLeveldb(budget, value.length);
    value = Buffer.from(value);
  }
  mergeRecord(records, origin, { sequence, type, value });
}

function tableRecords(buffer, budget) {
  requireLeveldb(buffer.length >= 48 && buffer.readBigUInt64LE(buffer.length - 8) === 0xdb4775248b80fb57n);
  const footer = buffer.length - 48;
  const cursor = { offset: footer, end: footer + 40 };
  const meta = blockHandle(buffer, cursor);
  const index = blockHandle(buffer, cursor);
  requireLeveldb(buffer.subarray(cursor.offset, cursor.end).every((byte) => byte === 0) && meta.offset + meta.size + 5 <= index.offset);
  for (const [key] of blockEntries(tableBlock(buffer, meta, footer, budget), budget)) requireLeveldb(key.length > 0);
  const records = new Map();
  let previousEnd = 0;
  for (const [key, value] of blockEntries(tableBlock(buffer, index, footer, budget), budget)) {
    requireLeveldb(key.length >= 8);
    const handleCursor = { offset: 0, end: value.length };
    const handle = blockHandle(value, handleCursor);
    requireLeveldb(handleCursor.offset === value.length && handle.offset >= previousEnd);
    for (const [internalKey, data] of blockEntries(tableBlock(buffer, handle, meta.offset, budget), budget)) {
      requireLeveldb(internalKey.length >= 8);
      const trailer = internalKey.readBigUInt64LE(internalKey.length - 8);
      const type = Number(trailer & 255n);
      requireLeveldb(type === 1 || (type === 0 && data.length === 0));
      rememberRecord(records, internalKey.subarray(0, -8), trailer >> 8n, type, data, budget);
    }
    previousEnd = handle.offset + handle.size + 5;
  }
  return records;
}

function writeBatchRecords(buffer, records, budget) {
  requireLeveldb(buffer.length >= 12);
  const sequence = buffer.readBigUInt64LE(0);
  const count = buffer.readUInt32LE(8);
  requireLeveldb(count <= Math.floor((buffer.length - 12) / 2) && sequence <= MAX_LEVELDB_SEQUENCE && sequence + BigInt(Math.max(0, count - 1)) <= MAX_LEVELDB_SEQUENCE);
  const cursor = { offset: 12, end: buffer.length };
  for (let index = 0; index < count; index++) {
    requireLeveldb(cursor.offset < cursor.end);
    const type = buffer[cursor.offset++];
    requireLeveldb(type === 0 || type === 1);
    const key = leveldbSlice(buffer, cursor);
    const value = type === 1 ? leveldbSlice(buffer, cursor) : null;
    rememberRecord(records, key, sequence + BigInt(index), type, value, budget);
  }
  requireLeveldb(cursor.offset === cursor.end);
}

function* logEntries(buffer, budget) {
  let offset = 0;
  let fragments = [];
  let fragmentBytes = 0;
  while (offset < buffer.length) {
    const end = Math.min(buffer.length, (Math.floor(offset / LEVELDB_LOG_BLOCK_BYTES) + 1) * LEVELDB_LOG_BLOCK_BYTES);
    if (end - offset < 7 || (buffer.readUInt32LE(offset) === 0 && buffer.readUInt16LE(offset + 4) === 0 && buffer[offset + 6] === 0)) {
      requireLeveldb(fragments.length === 0 && buffer.subarray(offset, end).every((byte) => byte === 0));
      offset = end;
      continue;
    }
    const length = buffer.readUInt16LE(offset + 4);
    const type = buffer[offset + 6];
    requireLeveldb(type >= 1 && type <= 4 && length <= end - offset - 7);
    requireLeveldb(buffer.readUInt32LE(offset) === maskedCrc32c(buffer, offset + 6, offset + 7 + length));
    const data = buffer.subarray(offset + 7, offset + 7 + length);
    const start = offset;
    offset += 7 + length;
    if (type === 1) {
      requireLeveldb(fragments.length === 0);
      yield data;
    } else {
      requireLeveldb(type === 2 ? fragments.length === 0 : fragments.length > 0 && start % LEVELDB_LOG_BLOCK_BYTES === 0);
      fragmentBytes += length;
      requireLeveldb(fragmentBytes <= MAX_LEVELDB_BYTES);
      fragments.push(data);
      if (type === 4) {
        spendLeveldb(budget, fragmentBytes);
        yield Buffer.concat(fragments, fragmentBytes);
        fragments = [];
        fragmentBytes = 0;
      } else requireLeveldb(offset === end && end % LEVELDB_LOG_BLOCK_BYTES === 0);
    }
  }
  requireLeveldb(fragments.length === 0);
}

function logRecords(buffer, budget) {
  const records = new Map();
  for (const data of logEntries(buffer, budget)) writeBatchRecords(data, records, budget);
  return records;
}

function manifestState(buffer, budget) {
  const state = { tables: new Map(), logNumber: null, previousLogNumber: 0n, nextFileNumber: null, lastSequence: null };
  for (const data of logEntries(buffer, budget)) {
    const cursor = { offset: 0, end: data.length };
    const additions = new Map();
    while (cursor.offset < cursor.end) {
      const tag = leveldbVarint(data, cursor);
      if (tag === 1) {
        requireLeveldb(leveldbSlice(data, cursor).equals(Buffer.from('leveldb.BytewiseComparator')));
      } else if (tag === 2) state.logNumber = leveldbUint64(data, cursor);
      else if (tag === 3) state.nextFileNumber = leveldbUint64(data, cursor);
      else if (tag === 4) {
        state.lastSequence = leveldbUint64(data, cursor);
        requireLeveldb(state.lastSequence <= MAX_LEVELDB_SEQUENCE);
      } else if (tag === 9) state.previousLogNumber = leveldbUint64(data, cursor);
      else if (tag === 5 || tag === 6 || tag === 7) {
        const level = leveldbVarint(data, cursor);
        requireLeveldb(level < 7);
        if (tag === 5) {
          const key = leveldbSlice(data, cursor);
          requireLeveldb(key.length >= 8 && key[key.length - 8] <= 1);
          continue;
        }
        const number = leveldbUint64(data, cursor);
        requireLeveldb(number > 0n);
        if (tag === 6) {
          if (state.tables.get(number)?.level === level) state.tables.delete(number);
        } else {
          const size = leveldbUint64(data, cursor);
          const smallest = leveldbSlice(data, cursor);
          const largest = leveldbSlice(data, cursor);
          requireLeveldb(size > 0n && smallest.length >= 8 && largest.length >= 8 && smallest[smallest.length - 8] <= 1 && largest[largest.length - 8] <= 1);
          requireLeveldb(!additions.has(number) && additions.size < MAX_LEVELDB_FILES);
          additions.set(number, { level, size });
        }
      } else requireLeveldb(false);
    }
    for (const [number, file] of additions) {
      requireLeveldb(!state.tables.has(number));
      state.tables.set(number, file);
    }
    requireLeveldb(state.tables.size <= MAX_LEVELDB_FILES);
  }
  requireLeveldb(state.logNumber !== null && state.nextFileNumber !== null && state.nextFileNumber > 0n && state.lastSequence !== null);
  return state;
}

function liveLeveldbFiles(entries, state) {
  const files = new Map();
  for (const entry of entries) {
    const match = /^([0-9]+)\.(log|ldb|sst)$/.exec(entry.name);
    if (!match) continue;
    const number = BigInt(match[1]);
    if (number > MAX_LEVELDB_FILE_NUMBER) continue;
    const isLog = match[2] === 'log';
    if (isLog ? number < state.logNumber && number !== state.previousLogNumber : !state.tables.has(number)) continue;
    requireLeveldb(entry.isFile() && !files.has(number) && files.size < MAX_LEVELDB_FILES);
    files.set(number, { name: entry.name, number, isLog, size: isLog ? null : state.tables.get(number).size });
  }
  for (const number of state.tables.keys()) requireLeveldb(files.has(number) && !files.get(number).isLog);
  for (const number of [state.logNumber, state.previousLogNumber]) {
    if (number > 0n) requireLeveldb(files.has(number) && files.get(number).isLog);
  }
  return [...files.values()].sort((left, right) => left.number < right.number ? -1 : left.number > right.number ? 1 : 0);
}

function sameLeveldbMetadata(left, right) {
  return ['dev', 'ino', 'size', 'mtimeNs', 'ctimeNs'].every((key) => left[key] === right[key]);
}

async function readLeveldbFile(path, maximum, observed) {
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const metadata = await file.stat({ bigint: true });
    requireLeveldb(metadata.isFile() && metadata.size >= 0n && metadata.size <= BigInt(maximum));
    const buffer = Buffer.alloc(Number(metadata.size));
    let offset = 0;
    while (offset < buffer.length) {
      const { bytesRead } = await file.read(buffer, offset, buffer.length - offset, offset);
      requireLeveldb(bytesRead > 0);
      offset += bytesRead;
    }
    for (const current of [await file.stat({ bigint: true }), await lstat(path, { bigint: true })]) {
      requireLeveldb(sameLeveldbMetadata(metadata, current));
    }
    if (observed) observed.set(path, metadata);
    return buffer;
  } finally {
    await file.close();
  }
}

export async function extractLeveldbTokens(directory) {
  try {
    let directoryMetadata;
    try {
      directoryMetadata = await lstat(directory, { bigint: true });
    } catch (error) {
      if (error.code === 'ENOENT') return [];
      throw error;
    }
    requireLeveldb(directoryMetadata.isDirectory());
    const entries = await readdir(directory, { withFileTypes: true });
    const observed = new Map();
    const currentPath = join(directory, 'CURRENT');
    const current = await readLeveldbFile(currentPath, 32, observed);
    const match = /^MANIFEST-([0-9]{1,20})\n$/.exec(current.toString('latin1'));
    requireLeveldb(match && match[0].length === current.length && BigInt(match[1]) > 0n && BigInt(match[1]) <= MAX_LEVELDB_FILE_NUMBER);
    const manifest = match[0].slice(0, -1);
    requireLeveldb(entries.some((entry) => entry.name === manifest && entry.isFile()));
    let remaining = MAX_LEVELDB_BYTES - current.length;
    const descriptor = await readLeveldbFile(join(directory, manifest), remaining, observed);
    remaining -= descriptor.length;
    const budget = { remaining: MAX_LEVELDB_BYTES };
    const state = manifestState(descriptor, budget);
    const files = liveLeveldbFiles(entries, state);
    const records = new Map();
    for (const entry of files) {
      const buffer = await readLeveldbFile(join(directory, entry.name), remaining, observed);
      remaining -= buffer.length;
      if (!entry.isLog) requireLeveldb(BigInt(buffer.length) === entry.size);
      const parsed = entry.isLog ? logRecords(buffer, budget) : tableRecords(buffer, budget);
      for (const [origin, record] of parsed) mergeRecord(records, origin, record);
    }
    const tokens = new Set();
    for (const record of records.values()) {
      if (record.type === 1) for (const token of extractTokens(record.value)) tokens.add(token);
    }
    const finalEntries = await readdir(directory, { withFileTypes: true });
    const names = (items) => items.map((entry) => entry.name);
    requireLeveldb(JSON.stringify(names(files)) === JSON.stringify(names(liveLeveldbFiles(finalEntries, state))));
    for (const [path, metadata] of [...observed].reverse()) requireLeveldb(sameLeveldbMetadata(metadata, await lstat(path, { bigint: true })));
    requireLeveldb(current.equals(await readLeveldbFile(currentPath, 32)));
    requireLeveldb(sameLeveldbMetadata(directoryMetadata, await lstat(directory, { bigint: true })));
    return [...tokens];
  } catch {
    throw new Error('Could not safely read Slack desktop LevelDB; quit Slack and try again');
  }
}
