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
  if (response.getResponseCode() !== 200) throw new Error('Drive media read failed');
  return response.getBlob();
}

function objectKey_(parent, name, role) {
  return sha_(Utilities.newBlob(JSON.stringify([parent, name, role])).getBytes());
}

function object_(parent, name, role, blob, config) {
  const checksum = blob ? sha_(blob.getBytes()) : null;
  const key = objectKey_(parent, name, role);
  const fields = 'id,name,parents,trashed,sha256Checksum,mimeType,appProperties';
  const q = "'" + driveId_(parent) + "' in parents and trashed = false and appProperties has { key='rowingLogObject' and value='" + key + "' }";
  const matches = list_({q, fields: 'nextPageToken,incompleteSearch,files(' + fields + ')', pageSize: 2});
  if (matches.files.length > 1 || matches.nextPageToken) throw new Error('Duplicate output object');
  const reservation = 'LOG_OBJECT_' + key;
  const reserved = config.props.getProperty(reservation);
  const expectedType = blob ? blob.getContentType() : FOLDER_MIME;
  const verify = item => {
    if (item.trashed || item.name !== name || item.mimeType !== expectedType ||
        !item.parents?.includes(parent) || item.appProperties?.rowingLogObject !== key ||
        (checksum && item.sha256Checksum !== checksum)) throw new Error('Output verification failed');
    if (reserved && item.id !== reserved) throw new Error('Output ID conflict');
    return item.id;
  };
  if (matches.files.length) {
    const id = verify(matches.files[0]);
    if (reserved) config.props.deleteProperty(reservation);
    return id;
  }
  if (!config.deadline || Date.now() >= config.deadline) throw new Error('Run time budget reached');
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
  requireViewer_(source);
  if (source.trashed || !source.parents?.includes(folder.id) || source.mimeType !== 'application/zip') {
    throw new Error('Source changed during scan');
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
  const versionFolder = object_(dayFolder, 'zip-' + driveId_(source.id).toLowerCase() + '-' +
    sha_(Utilities.newBlob(source.id).getBytes()).slice(0, 16) + '-' + version, 'version', null, config);
  const commit = named_(versionFolder, 'ready.json', 'id,appProperties');
  if (commit) {
    if (commit.appProperties?.rowingLogObject !== objectKey_(versionFolder, 'ready.json', 'commit')) throw new Error('Unexpected ready marker');
    return 'existing';
  }
  const rejected = named_(versionFolder, 'rejected.json', 'id,appProperties');
  if (rejected) {
    if (rejected.appProperties?.rowingLogObject !== objectKey_(versionFolder, 'rejected.json', 'rejected')) throw new Error('Unexpected rejected marker');
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
  const after = Drive.Files.get(source.id, {supportsAllDrives: true, fields: 'version,parents,trashed,capabilities(canEdit,canTrash,canDelete)'});
  requireViewer_(after);
  if (after.trashed || String(after.version) !== version || !after.parents?.includes(folder.id) ||
      bytes.length !== size || (source.sha256Checksum && sha_(bytes) !== source.sha256Checksum)) {
    throw new Error('Source changed during download');
  }
  const zipId = object_(versionFolder, 'source.zip', 'zip', archive, config);
  if (!match) return 'waitingMetadata';
  const pending = 'LOG_PENDING_' + versionFolder;
  const work = {meta, versionFolder, zipId, hash: sha_(bytes)};
  config.props.setProperty(pending, JSON.stringify(work));
  return finishOne_(config, pending, work, archive);
}

function finishOne_(config, pending, work, archive) {
  const {meta, versionFolder, zipId, hash} = work;
  const existing = named_(versionFolder, 'ready.json', 'id,appProperties');
  if (existing) {
    if (existing.appProperties?.rowingLogObject !== objectKey_(versionFolder, 'ready.json', 'commit')) {
      throw new Error('Unexpected ready marker');
    }
    config.props.deleteProperty(pending);
    return 'existing';
  }
  const archived = Drive.Files.get(zipId, {fields: 'parents,trashed,sha256Checksum'});
  if (archived.trashed || !archived.parents?.includes(versionFolder) || archived.sha256Checksum !== hash) {
    throw new Error('Archived ZIP location or checksum changed');
  }
  const zip = archive || download_(zipId);
  const bytes = zip.getBytes();
  if (sha_(bytes) !== hash) throw new Error('Archived ZIP verification failed');
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
