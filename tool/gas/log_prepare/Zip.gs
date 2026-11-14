class ArchiveError extends Error {}

function zipEntries_(bytes) {
  const reject = message => { throw new ArchiveError(message); };
  const u16 = i => (bytes[i] & 255) | ((bytes[i + 1] & 255) << 8);
  const u32 = i => (u16(i) + u16(i + 2) * 65536);
  let end = bytes.length - 22;
  const earliest = Math.max(0, end - 65535);
  while (end >= earliest && (u32(end) !== 0x06054b50 || end + 22 + u16(end + 20) !== bytes.length)) end--;
  if (end < earliest || u16(end + 4) || u16(end + 6)) reject('invalid_zip_directory');
  const count = u16(end + 10);
  const start = u32(end + 16);
  if (!count || count > 250 || count !== u16(end + 8) || start + u32(end + 12) !== end) {
    reject('unsupported_zip_directory');
  }
  const entries = new Map();
  const paths = new Map();
  const spans = [];
  let pos = start;
  let total = 0;
  for (let i = 0; i < count; i++) {
    if (pos + 46 > end || u32(pos) !== 0x02014b50) reject('invalid_zip_entry');
    const flags = u16(pos + 8);
    const method = u16(pos + 10);
    const crc = u32(pos + 16);
    const compressed = u32(pos + 20);
    const size = u32(pos + 24);
    const length = u16(pos + 28);
    const next = pos + 46 + length + u16(pos + 30) + u16(pos + 32);
    const type = u32(pos + 38) >>> 28;
    const local = u32(pos + 42);
    if (!length || length > 1024 || next > end || u16(pos + 34) ||
        (flags & ~0x080e) || ![0, 8].includes(method) || (type && type !== 8 && type !== 4) ||
        local + 30 > start || u32(local) !== 0x04034b50 ||
        u16(local + 6) !== flags || u16(local + 8) !== method ||
        u16(local + 26) !== length) reject('unsupported_zip_entry');
    if (!(flags & 8) && (u32(local + 14) !== crc || u32(local + 18) !== compressed ||
        u32(local + 22) !== size)) reject('zip_header_mismatch');
    const data = local + 30 + length + u16(local + 28);
    if (data + compressed > start || (method === 0 && compressed !== size)) reject('invalid_zip_extent');
    const nameBytes = bytes.slice(pos + 46, pos + 46 + length);
    if (nameBytes.some((b, j) => b !== bytes[local + 30 + j])) reject('zip_header_mismatch');
    let extentEnd = data + compressed;
    if (flags & 8) {
      if (u32(extentEnd) === 0x08074b50) extentEnd += 4;
      if (extentEnd + 12 > start || u32(extentEnd) !== crc ||
          u32(extentEnd + 4) !== compressed || u32(extentEnd + 8) !== size) reject('invalid_zip_descriptor');
      extentEnd += 12;
    }
    spans.push([local, extentEnd]);
    const name = Utilities.newBlob(nameBytes).getDataAsString('UTF-8');
    const roundTrip = Utilities.newBlob(name).getBytes();
    if (roundTrip.length !== length || roundTrip.some((b, j) => b !== nameBytes[j])) reject('invalid_zip_encoding');
    const directory = name.endsWith('/');
    const parts = (directory ? name.slice(0, -1) : name).split('/');
    if (parts.length > 16 || /[\\:\x00-\x1f\x7f]/.test(name) ||
        parts.some(p => !p || p === '.' || p === '..' || p.length > 200) ||
        (type === 4 && !directory) || (type === 8 && directory) ||
        (directory && (size || crc))) reject('unsafe_zip_path');
    const canonical = parts.map(p => p.normalize('NFC').toUpperCase().toLowerCase()).join('/');
    if (paths.has(canonical)) reject('duplicate_zip_path');
    paths.set(canonical, directory);
    entries.set(name, {directory, size, crc});
    total += size;
    if (total > 24 * 1024 * 1024) reject('expanded_size_limit');
    pos = next;
  }
  if (pos !== end) reject('invalid_zip_directory');
  spans.sort((a, b) => a[0] - b[0]);
  for (let i = 1; i < spans.length; i++) {
    if (spans[i][0] < spans[i - 1][1]) reject('overlapping_zip_entries');
  }
  for (const path of paths.keys()) {
    const parts = path.split('/');
    for (let i = 1; i < parts.length; i++) {
      if (paths.get(parts.slice(0, i).join('/')) === false) reject('zip_file_directory_collision');
    }
  }
  return entries;
}

const CRC_TABLE = Array.from({length: 256}, (_, n) => {
  for (let i = 0; i < 8; i++) n = (n >>> 1) ^ ((n & 1) ? 0xedb88320 : 0);
  return n;
});

function crc32_(bytes) {
  let crc = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) crc = (crc >>> 8) ^ CRC_TABLE[(crc ^ bytes[i]) & 255];
  return (crc ^ 0xffffffff) >>> 0;
}

function expandVerified_(archive, entries) {
  let blobs;
  try {
    blobs = Utilities.unzip(archive);
  } catch (error) {
    // Runtime and quota failures also surface here. Keep the version retryable.
    throw new Error('unzip_failed');
  }
  const files = new Map();
  for (const blob of blobs) {
    const path = blob.getName();
    const entry = entries.get(path);
    if (!entry || files.has(path)) throw new ArchiveError('unexpected_extracted_entry');
    const bytes = blob.getBytes();
    if (entry.size !== bytes.length || entry.crc !== crc32_(bytes)) throw new ArchiveError('zip_crc_mismatch');
    files.set(path, blob);
  }
  for (const [name, entry] of entries) {
    if (!entry.directory && !files.has(name)) throw new ArchiveError('missing_extracted_entry');
  }
  return files;
}
