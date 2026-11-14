/** Daily preparation in the upload project. The web app uses the script lock. */

const FOLDER_MIME = 'application/vnd.google-apps.folder';
const FILE_FIELDS = 'id,name,mimeType,parents,trashed,createdTime,version,size,sha256Checksum,description,capabilities(canAddChildren)';
const DAILY_HANDLER = 'prepareLogsDaily';
const MAX_ZIP = 12 * 1024 * 1024;
const DRIVE_LIST_OPTIONS = {supportsAllDrives: true, includeItemsFromAllDrives: true};

// Run once from the Apps Script editor as the account deploying the upload web app.
function enableDailyLogPreparation() {
  initializeLogOutput_();
  installDailyLogPreparation_();
  prepareLogsDaily();
}

function initializeLogOutput_() {
  const lock = LockService.getUserLock();
  lock.waitLock(1000);
  try {
    const props = PropertiesService.getScriptProperties();
    if (props.getProperty('LOG_OUTPUT_ID')) {
      config_();
      return;
    }
    sourceRoot_(props);
    const reservation = 'LOG_OUTPUT_RESERVED_ID';
    const existing = props.getProperty(reservation);
    const id = driveId_(existing || Drive.Files.generateIds({count: 1, space: 'drive'}).ids[0]);
    if (!existing) props.setProperty(reservation, id);
    try {
      Drive.Files.create({
        id, name: 'Rowing Navigator - analysis preparation', mimeType: FOLDER_MIME,
        appProperties: {rowingLogRole: 'output-v1'}
      }, null, {fields: 'id'});
    } catch (error) {
      // A timeout can arrive after Drive creates the reserved folder.
    }
    const output = Drive.Files.get(id, {
      fields: 'id,webViewLink,mimeType,trashed,parents,capabilities(canAddChildren),appProperties'
    });
    if (output.trashed || output.mimeType !== FOLDER_MIME || !output.capabilities?.canAddChildren ||
        output.appProperties?.rowingLogRole !== 'output-v1') throw new Error('Invalid initialized output');
    ensureSeparateTree_(output, props.getProperty('ROOT_FOLDER_ID'));
    props.setProperty('LOG_OUTPUT_ID', output.id);
    props.deleteProperty(reservation);
    console.log(JSON.stringify(output));
  } finally {
    lock.releaseLock();
  }
}

function installDailyLogPreparation_() {
  const lock = LockService.getUserLock();
  lock.waitLock(1000);
  try {
    config_();
    const triggers = ScriptApp.getProjectTriggers().filter(t => t.getHandlerFunction() === DAILY_HANDLER);
    if (triggers.length > 1) throw new Error('Remove duplicate daily triggers in the editor');
    if (triggers.length === 0) {
      ScriptApp.newTrigger(DAILY_HANDLER).timeBased().atHour(4).everyDays(1).inTimezone('Asia/Tokyo').create();
    }
  } finally {
    lock.releaseLock();
  }
}

function prepareLogsDaily() {
  const lock = LockService.getUserLock();
  if (!lock.tryLock(1000)) throw new Error('Log preparation is already running');
  try {
    const config = config_();
    const deadline = Date.now() + 255000;
    config.deadline = deadline;
    const prior = config.props.getProperty('LOG_SCAN_STATE');
    const state = prior ? JSON.parse(prior) : {rootPage: '', folders: [], folderIndex: 0, filePage: '', fileIndex: 0};
    if (state.source && (state.source !== config.source || state.output !== config.output)) {
      throw new Error('Source or output changed. Use a separate GAS project for the new configuration.');
    }
    state.source = config.source;
    state.output = config.output;
    const counts = {scanned: 0, prepared: 0, existing: 0, rejected: 0, retry: 0, waitingMetadata: 0};
    const pendingKeys = config.props.getKeys().filter(key => key.startsWith('LOG_PENDING_'));
    for (const key of pendingKeys) {
      if (Date.now() >= deadline) break;
      try {
        counts[finishOne_(config, key, JSON.parse(config.props.getProperty(key)))]++;
      } catch (error) {
        counts.retry++;
        console.warn(JSON.stringify({pending: key, failure: logFailureCode_(error)}));
      }
    }
    let complete = false;
    while (Date.now() < deadline) {
      if (!state.folders.length) {
        const page = list_({
          q: "'" + config.source + "' in parents and trashed = false and mimeType = '" + FOLDER_MIME + "'",
          orderBy: 'name', pageSize: 40, pageToken: state.rootPage || undefined, fields: 'nextPageToken,incompleteSearch,files(id,name)'
        });
        state.folders = page.files.filter(f => /^\d{4}-\d{2}-\d{2}$/.test(f.name)).map(f => f.id);
        state.nextRootPage = page.nextPageToken || '';
      }
      while (state.folderIndex < state.folders.length && Date.now() < deadline) {
        const folderId = state.folders[state.folderIndex];
        const folder = Drive.Files.get(folderId, {supportsAllDrives: true, fields: 'id,name,parents,trashed'});
        if (folder.trashed || !folder.parents?.includes(config.source) || !/^\d{4}-\d{2}-\d{2}$/.test(folder.name)) {
          throw new Error('Source date folder moved or changed during scan');
        }
        if (!state.files) {
          const page = list_({
            q: "'" + folderId + "' in parents and trashed = false and mimeType = 'application/zip'",
            orderBy: 'createdTime', pageSize: 20, pageToken: state.filePage || undefined,
            fields: 'nextPageToken,incompleteSearch,files(id)'
          });
          state.files = page.files.map(file => file.id);
          state.nextFilePage = page.nextPageToken || '';
          checkpoint_(config, state);
        }
        while (state.fileIndex < state.files.length && Date.now() < deadline) {
          const fileId = state.files[state.fileIndex];
          counts.scanned++;
          try {
            counts[prepareOne_(config, folder, fileId)]++;
          } catch (error) {
            counts.retry++;
            console.warn(JSON.stringify({sourceId: fileId, failure: logFailureCode_(error)}));
          }
          state.fileIndex++;
          checkpoint_(config, state);
        }
        if (state.fileIndex < state.files.length) break;
        state.filePage = state.nextFilePage;
        state.fileIndex = 0;
        delete state.files;
        delete state.nextFilePage;
        if (!state.filePage) state.folderIndex++;
        checkpoint_(config, state);
      }
      if (state.folderIndex < state.folders.length) break;
      if (!state.nextRootPage) {
        complete = true;
        break;
      }
      state.rootPage = state.nextRootPage;
      state.folders = [];
      state.folderIndex = 0;
      checkpoint_(config, state);
    }
    if (complete) {
      // Keep the binding and reset the cursor for the next full sweep.
      config.props.setProperty('LOG_SCAN_STATE', JSON.stringify({
        source: config.source, output: config.output, rootPage: '', folders: [], folderIndex: 0, filePage: '', fileIndex: 0
      }));
    } else {
      checkpoint_(config, state);
    }
    config.props.setProperty('LOG_LAST_RUN', JSON.stringify({
      at: new Date().toISOString(), complete, ...counts
    }));
    console.log(config.props.getProperty('LOG_LAST_RUN'));
    if (counts.retry || counts.waitingMetadata || counts.rejected) throw new Error('Some source ZIPs remain unresolved. See LOG_LAST_RUN and execution logs.');
  } catch (error) {
    console.error('Daily preparation stopped. Inspect LOG_LAST_RUN and execution details.');
    throw error;
  } finally {
    lock.releaseLock();
  }
}

function restartLogScan() {
  const lock = LockService.getUserLock();
  lock.waitLock(1000);
  try {
    const config = config_();
    const state = JSON.parse(config.props.getProperty('LOG_SCAN_STATE') || '{}');
    if (state.source && (state.source !== config.source || state.output !== config.output)) {
      throw new Error('Source or output changed. Use a separate GAS project.');
    }
    config.props.setProperty('LOG_SCAN_STATE', JSON.stringify({
      source: config.source, output: config.output, rootPage: '', folders: [], folderIndex: 0, filePage: '', fileIndex: 0
    }));
  } finally {
    lock.releaseLock();
  }
}

class LogPreparationError extends Error {}

function logFailureCode_(error) {
  if (error instanceof LogPreparationError || error instanceof ArchiveError) return error.message;
  const message = String(error?.message || '');
  if (/quota|service invoked too many times|limit exceeded/i.test(message)) return 'google_service_limit';
  if (/not found|file not found/i.test(message)) return 'drive_object_not_found';
  if (/permission|forbidden|unauthorized/i.test(message)) return 'drive_permission_denied';
  return 'unexpected_preparation_error';
}

function checkpoint_(config, state) {
  config.props.setProperty('LOG_SCAN_STATE', JSON.stringify(state));
}

function list_(options) {
  const page = Drive.Files.list({...DRIVE_LIST_OPTIONS, ...options});
  if (page.incompleteSearch) throw new LogPreparationError('drive_incomplete_search');
  return {...page, files: page.files || []};
}

function driveId_(id) {
  if (typeof id !== 'string' || !/^[A-Za-z0-9_-]{10,160}$/.test(id)) throw new Error('Invalid Drive ID');
  return id;
}

function sourceRoot_(props) {
  const source = props.getProperty('ROOT_FOLDER_ID');
  if (!source) throw new Error('ROOT_FOLDER_ID is missing. Check the existing upload project settings.');
  driveId_(source);
  const root = Drive.Files.get(source, {supportsAllDrives: true, fields: FILE_FIELDS});
  if (root.trashed || root.mimeType !== FOLDER_MIME) throw new Error('Source folder unavailable');
  return root;
}

function config_() {
  const props = PropertiesService.getScriptProperties();
  const sourceItem = sourceRoot_(props);
  const source = sourceItem.id;
  const output = driveId_(props.getProperty('LOG_OUTPUT_ID'));
  const item = Drive.Files.get(output, {fields: FILE_FIELDS + ',appProperties'});
  if (output === source || item.trashed || item.mimeType !== FOLDER_MIME ||
      !item.capabilities?.canAddChildren || item.appProperties?.rowingLogRole !== 'output-v1') {
    throw new Error('Invalid output folder. Check the output folder created by enableDailyLogPreparation.');
  }
  ensureSeparateTree_(item, source);
  ensureSeparateTree_(sourceItem, output);
  return {props, source, output, outputFolders: new Map([[output, null]])};
}

function ensureSeparateTree_(item, forbiddenAncestor) {
  const pending = [...(item.parents || [])];
  const visited = new Set();
  while (pending.length) {
    const id = pending.pop();
    if (id === forbiddenAncestor) throw new Error('Source and output folders must be separate');
    if (visited.has(id)) continue;
    visited.add(id);
    if (visited.size > 100) throw new Error('Unable to verify folder ancestry');
    const parent = Drive.Files.get(id, {supportsAllDrives: true, fields: 'parents,trashed'});
    if (parent.trashed) throw new Error('Folder ancestor is in trash');
    pending.push(...(parent.parents || []));
  }
}

function sha_(bytes) {
  return Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, bytes)
    .map(b => (b & 255).toString(16).padStart(2, '0')).join('');
}

function jsonBlob_(data) {
  return Utilities.newBlob(JSON.stringify(data) + '\n', 'application/json');
}

function download_(id) {
  const url = 'https://www.googleapis.com/drive/v3/files/' + driveId_(id) + '?alt=media&supportsAllDrives=true';
  const response = UrlFetchApp.fetch(url, {
    headers: {Authorization: 'Bearer ' + ScriptApp.getOAuthToken()},
    muteHttpExceptions: true,
    followRedirects: false
  });
  const status = response.getResponseCode();
  if (status !== 200) throw new LogPreparationError('drive_media_http_' + status);
  return response.getBlob();
}

function objectKey_(parent, name, role) {
  return sha_(Utilities.newBlob(JSON.stringify([parent, name, role])).getBytes());
}

function object_(parent, name, role, blob, config) {
  if (!config.outputFolders.has(parent) || parent === config.source) {
    throw new Error('Write target is outside the output tree');
  }
  const checksum = blob ? sha_(blob.getBytes()) : null;
  const key = objectKey_(parent, name, role);
  const fields = 'id,name,parents,trashed,sha256Checksum,mimeType,appProperties';
  const q = "'" + driveId_(parent) + "' in parents and trashed = false and appProperties has { key='rowingLogObject' and value='" + key + "' }";
  const matches = list_({q, fields: 'nextPageToken,incompleteSearch,files(' + fields + ')', pageSize: 2});
  if (matches.files.length > 1 || matches.nextPageToken) throw new LogPreparationError('duplicate_output_object');
  const reservation = 'LOG_OBJECT_' + key;
  const reserved = config.props.getProperty(reservation);
  const expectedType = blob ? blob.getContentType() : FOLDER_MIME;
  const verify = item => {
    if (item.trashed || item.name !== name || item.parents?.length !== 1 ||
        item.parents[0] !== parent || item.appProperties?.rowingLogObject !== key) {
      throw new LogPreparationError('output_identity_mismatch');
    }
    // Drive can infer a different MIME type from a filename or the bytes.
    // Require exact bytes and reject Workspace conversions and shortcuts.
    if (blob ? (!item.mimeType || item.mimeType.startsWith('application/vnd.google-apps.')) :
      item.mimeType !== FOLDER_MIME) {
      throw new LogPreparationError('output_type_mismatch');
    }
    if (blob && (item.sha256Checksum || sha_(download_(item.id).getBytes())) !== checksum) {
      throw new LogPreparationError('output_checksum_mismatch');
    }
    if (reserved && item.id !== reserved) throw new LogPreparationError('output_id_conflict');
    if (!blob) config.outputFolders.set(item.id, {parent, key});
    return item.id;
  };
  if (matches.files.length) {
    const id = verify(matches.files[0]);
    if (reserved) config.props.deleteProperty(reservation);
    return id;
  }
  if (!config.deadline || Date.now() >= config.deadline) throw new LogPreparationError('run_time_budget_reached');
  verifyWriteParent_(config, parent);
  const id = reserved || Drive.Files.generateIds({count: 1, space: 'drive'}).ids[0];
  driveId_(id);
  if (!reserved) config.props.setProperty(reservation, id);
  try {
    Drive.Files.create({
      id, name, mimeType: expectedType, parents: [parent], appProperties: {rowingLogObject: key}
    }, blob, {fields: 'id'});
  } catch (error) {
    // The request may have succeeded. Verify the reserved ID before any retry.
  }
  const result = verify(Drive.Files.get(id, {fields}));
  config.props.deleteProperty(reservation);
  return result;
}

function verifyWriteParent_(config, id) {
  const seen = new Set();
  while (id !== config.output) {
    const expected = config.outputFolders.get(id);
    if (id === config.source || !expected || seen.has(id)) throw new Error('Unexpected output ancestry');
    seen.add(id);
    const item = Drive.Files.get(id, {fields: 'mimeType,parents,trashed,appProperties'});
    if (item.trashed || item.mimeType !== FOLDER_MIME || item.parents?.length !== 1 ||
        item.parents[0] !== expected.parent || item.appProperties?.rowingLogObject !== expected.key) {
      throw new LogPreparationError('output_folder_moved');
    }
    id = expected.parent;
  }
  const root = Drive.Files.get(id, {fields: 'mimeType,parents,trashed,appProperties'});
  if (root.trashed || root.mimeType !== FOLDER_MIME || root.appProperties?.rowingLogRole !== 'output-v1') {
    throw new Error('Output root changed during preparation');
  }
  ensureSeparateTree_(root, config.source);
}

function named_(parent, name, fields) {
  // Callers use generated ASCII names.
  if (!/^[a-z0-9._-]+$/.test(name)) throw new Error('Invalid generated name');
  const page = list_({
    q: "'" + driveId_(parent) + "' in parents and trashed = false and name = '" + name + "'",
    pageSize: 2, fields: 'nextPageToken,incompleteSearch,files(' + fields + ')'
  });
  if (page.nextPageToken || page.files.length > 1) throw new Error('Duplicate published object');
  return page.files[0];
}

function prepareOne_(config, folder, sourceId) {
  const source = Drive.Files.get(sourceId, {supportsAllDrives: true, fields: FILE_FIELDS});
  if (source.trashed || !source.parents?.includes(folder.id) || source.mimeType !== 'application/zip') {
    throw new LogPreparationError('source_changed_during_scan');
  }
  const match = /^key=([A-Za-z0-9_-]{1,128})\/([A-Za-z0-9]{1,128})\/(session|practiceLog)\/([A-Za-z0-9_-]{1,64})$/
    .exec((source.description || '').split('\n')[0]);
  const version = String(source.version || '');
  if (!/^\d+$/.test(version) || !/^\d{4}-\d\d-\d\dT/.test(source.createdTime || '')) {
    throw new Error('Source version unavailable');
  }
  // Drive metadata changes can advance version without changing the payload.
  // The archive itself is identified by the hash of the bytes.
  const day = folder.name;
  const dayFolder = object_(config.output, day, 'day', null, config);
  const versionFolder = object_(dayFolder, versionName_(source.id, version), 'version', null, config);
  const commit = named_(versionFolder, 'ready.json', 'id,appProperties');
  if (commit) {
    if (commit.appProperties?.rowingLogObject !== objectKey_(versionFolder, 'ready.json', 'commit')) throw new LogPreparationError('unexpected_ready_marker');
    return 'existing';
  }
  const rejected = named_(versionFolder, 'rejected.json', 'id,appProperties');
  if (rejected) {
    if (rejected.appProperties?.rowingLogObject !== objectKey_(versionFolder, 'rejected.json', 'rejected')) throw new LogPreparationError('unexpected_rejected_marker');
    console.warn(JSON.stringify({sourceId: source.id, rejectedId: rejected.id}));
    return 'rejected';
  }
  const meta = {
    schema: 1, sourceId: source.id, sourceVersion: version, receivedAt: source.createdTime,
    day, record: match ? sha_(Utilities.newBlob(match[0]).getBytes()) : null,
    kind: match?.[3] || null
  };
  const size = Number(source.size);
  if (!Number.isSafeInteger(size) || size < 0) throw new Error('Source size unavailable');
  if (size > MAX_ZIP) {
    object_(versionFolder, 'rejected.json', 'rejected', jsonBlob_({...meta, code: 'compressed_size_limit'}), config);
    console.warn(JSON.stringify({sourceId: source.id, failure: 'compressed_size_limit'}));
    return 'rejected';
  }
  const original = named_(versionFolder, 'source.zip', 'id');
  const archive = original ? download_(original.id) : download_(source.id);
  archive.setContentType('application/zip');
  const bytes = archive.getBytes();
  const after = Drive.Files.get(source.id, {supportsAllDrives: true, fields: 'version,parents,trashed'});
  if (after.trashed || String(after.version) !== version || !after.parents?.includes(folder.id) ||
      bytes.length !== size || (source.sha256Checksum && sha_(bytes) !== source.sha256Checksum)) {
    throw new LogPreparationError('source_changed_during_download');
  }
  const zipId = object_(versionFolder, 'source.zip', 'zip', archive, config);
  if (!match) return 'waitingMetadata';
  const pending = 'LOG_PENDING_' + versionFolder;
  const work = {meta, versionFolder, zipId, hash: sha_(bytes)};
  config.props.setProperty(pending, JSON.stringify(work));
  return finishOne_(config, pending, work, archive);
}

function versionName_(id, version) {
  if (!/^\d+$/.test(version)) throw new Error('Invalid source version');
  return 'zip-' + driveId_(id).toLowerCase() + '-' +
    sha_(Utilities.newBlob(id).getBytes()).slice(0, 16) + '-' + version;
}

function verifyOutputVersion_(config, versionFolder, meta) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(meta.day)) throw new Error('Invalid output day');
  const fields = 'id,name,parents,mimeType,trashed,appProperties';
  const version = Drive.Files.get(driveId_(versionFolder), {fields});
  const dayId = driveId_(version.parents?.[0]);
  const day = Drive.Files.get(dayId, {fields});
  for (const [item, parent, name, role] of [
    [day, config.output, meta.day, 'day'],
    [version, dayId, versionName_(meta.sourceId, meta.sourceVersion), 'version']
  ]) {
    if (item.id === config.source || item.trashed || item.mimeType !== FOLDER_MIME ||
        item.parents?.length !== 1 || item.parents[0] !== parent || item.name !== name ||
        item.appProperties?.rowingLogObject !== objectKey_(parent, name, role)) {
      throw new Error('Saved version is outside the expected output tree');
    }
  }
  config.outputFolders.set(dayId, {parent: config.output, key: day.appProperties.rowingLogObject});
  config.outputFolders.set(versionFolder, {parent: dayId, key: version.appProperties.rowingLogObject});
}

function finishOne_(config, pending, work, archive) {
  const {meta, versionFolder, zipId, hash} = work;
  verifyOutputVersion_(config, versionFolder, meta);
  const existing = named_(versionFolder, 'ready.json', 'id,appProperties');
  if (existing) {
    if (existing.appProperties?.rowingLogObject !== objectKey_(versionFolder, 'ready.json', 'commit')) {
      throw new LogPreparationError('unexpected_ready_marker');
    }
    config.props.deleteProperty(pending);
    return 'existing';
  }
  const archived = Drive.Files.get(zipId, {fields: 'parents,trashed,sha256Checksum'});
  if (archived.trashed || !archived.parents?.includes(versionFolder)) {
    throw new LogPreparationError('archived_zip_location_changed');
  }
  if (archived.sha256Checksum && archived.sha256Checksum !== hash) {
    throw new LogPreparationError('archived_zip_checksum_mismatch');
  }
  const zip = archive && archived.sha256Checksum ? archive : download_(zipId);
  const bytes = zip.getBytes();
  if (sha_(bytes) !== hash) throw new LogPreparationError('archived_zip_checksum_mismatch');
  let entries, files;
  try {
    entries = zipEntries_(bytes);
    files = expandVerified_(zip, entries);
  } catch (error) {
    if (!(error instanceof ArchiveError)) throw error;
    object_(versionFolder, 'rejected.json', 'rejected', jsonBlob_({...meta, zipId, code: error.message}), config);
    config.props.deleteProperty(pending);
    console.warn(JSON.stringify({sourceId: meta.sourceId, failure: error.message}));
    return 'rejected';
  }
  const base = object_(versionFolder, 'files', 'tree', null, config);
  const folders = new Map([['', base]]);
  const inventory = [];
  for (const [path, entry] of entries) {
    const parts = (entry.directory ? path.slice(0, -1) : path).split('/');
    const folderParts = entry.directory ? parts : parts.slice(0, -1);
    let prefix = '';
    let parent = base;
    for (const part of folderParts) {
      prefix += part + '/';
      if (!folders.has(prefix)) folders.set(prefix, object_(parent, part, 'directory', null, config));
      parent = folders.get(prefix);
    }
    if (entry.directory) {
      inventory.push({path, directory: true, id: parent});
      continue;
    }
    const file = files.get(path);
    file.setContentType('application/octet-stream');
    const id = object_(parent, parts.at(-1), 'entry', file, config);
    inventory.push({path, id, size: entry.size, sha256: sha_(file.getBytes())});
  }
  const prepared = prepareIndex_(files);
  const indexId = object_(versionFolder, 'events-index.jsonl', 'index', prepared.index, config);
  object_(versionFolder, 'ready.json', 'commit', jsonBlob_({
    ...meta, zipId, zipSha256: hash, files: inventory, summary: prepared.summary, indexId,
    indexSha256: sha_(prepared.index.getBytes())
  }), config);
  config.props.deleteProperty(pending);
  return 'prepared';
}

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
    throw new LogPreparationError('unzip_failed');
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

function prepareIndex_(files) {
  const index = [];
  const summary = {tracks: [], events: [], manifests: []};
  for (const [path, blob] of files) {
    const name = path.split('/').at(-1);
    if (['manifest.json', 'practice_manifest.json'].includes(name)) {
      try {
        const manifest = JSON.parse(blob.getDataAsString('UTF-8'));
        const allowed = value => typeof value === 'string' ? value.slice(0, 80) : undefined;
        summary.manifests.push({path, startedAt: allowed(manifest.startedAt),
          appVersion: allowed(manifest.app?.version), build: allowed(manifest.app?.buildNumber)});
      } catch (error) {
        summary.manifests.push({path, invalid: true});
      }
      continue;
    }
    if (name === 'track.csv' || name === 'tracks.csv') {
      const lines = blob.getDataAsString('UTF-8').split(/\r?\n/);
      summary.tracks.push({path, dataLines: lines.slice(1).filter(Boolean).length});
      continue;
    }
    if (name !== 'events.jsonl' && name !== 'alerts.jsonl') continue;
    const lines = blob.getDataAsString('UTF-8').split(/\r?\n/);
    const types = new Map();
    let invalid = 0;
    let omitted = 0;
    for (let i = 0; i < lines.length; i++) {
      if (!lines[i].trim()) continue;
      try {
        const event = JSON.parse(lines[i]);
        if (!event || typeof event !== 'object' || Array.isArray(event)) throw new Error('invalid event');
        const token = value => typeof value === 'string' && /^[A-Za-z0-9_.:-]{1,100}$/.test(value) ? value : null;
        const type = token(event.type || event.event || event.category || event.kind) || 'unknown';
        const time = event.t ?? event.time ?? event.timestamp ?? event.utc_time ?? event.occurredAt;
        types.set(type, (types.get(type) || 0) + 1);
        if (index.length < 40000) {
          index.push(JSON.stringify({path, line: i + 1, type, category: token(event.category),
            time: typeof time === 'number' && Number.isFinite(time) ? time : token(time)}));
        } else {
          omitted++;
        }
      } catch (error) {
        invalid++;
      }
    }
    summary.events.push({path, types: Array.from(types).slice(0, 200), typeCount: types.size, invalid, omitted});
  }
  return {summary, index: Utilities.newBlob(index.join('\n') + (index.length ? '\n' : ''), 'application/octet-stream')};
}
