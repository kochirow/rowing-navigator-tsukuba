const FOLDER_MIME = 'application/vnd.google-apps.folder';
const FILE_FIELDS = 'id,name,mimeType,parents,trashed,createdTime,version,size,sha256Checksum,description,capabilities(canEdit,canTrash,canDelete,canAddChildren)';
const DAILY_HANDLER = 'prepareLogsDaily';
const MAX_ZIP = 12 * 1024 * 1024;
const DRIVE_LIST_OPTIONS = {supportsAllDrives: true, includeItemsFromAllDrives: true};

function initializeLogOutput() {
  const lock = LockService.getScriptLock();
  lock.waitLock(1000);
  try {
    const props = PropertiesService.getScriptProperties();
    if (props.getProperty('LOG_OUTPUT_ID')) throw new Error('LOG_OUTPUT_ID already configured');
    sourceRoot_(props);
    const output = Drive.Files.create({
      name: 'Rowing Navigator - analysis preparation',
      mimeType: FOLDER_MIME,
      appProperties: {rowingLogRole: 'output-v1'}
    }, null, {fields: 'id,webViewLink'});
    props.setProperty('LOG_OUTPUT_ID', output.id);
    console.log(JSON.stringify(output));
  } finally {
    lock.releaseLock();
  }
}

function installDailyLogPreparation() {
  const lock = LockService.getScriptLock();
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
  const lock = LockService.getScriptLock();
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
        console.warn(JSON.stringify({pending: key, failure: 'resume_failed'}));
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
        const folder = Drive.Files.get(folderId, {supportsAllDrives: true, fields: 'id,name,parents,trashed,capabilities(canEdit,canTrash,canDelete)'});
        if (folder.trashed || !folder.parents?.includes(config.source) || !/^\d{4}-\d{2}-\d{2}$/.test(folder.name)) {
          throw new Error('Source date folder moved or changed during scan');
        }
        requireViewer_(folder);
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
            console.warn(JSON.stringify({sourceId: fileId, failure: error instanceof ArchiveError ? error.message : 'processing_failed'}));
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
  const lock = LockService.getScriptLock();
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

function checkpoint_(config, state) {
  config.props.setProperty('LOG_SCAN_STATE', JSON.stringify(state));
}

function list_(options) {
  const page = Drive.Files.list({...DRIVE_LIST_OPTIONS, ...options});
  if (page.incompleteSearch) throw new Error('Drive returned incomplete search');
  return {...page, files: page.files || []};
}

function driveId_(id) {
  if (typeof id !== 'string' || !/^[A-Za-z0-9_-]{10,160}$/.test(id)) throw new Error('Invalid Drive ID');
  return id;
}

function requireViewer_(file) {
  const caps = file.capabilities || {};
  if (caps.canEdit !== false || caps.canTrash !== false || caps.canDelete !== false) {
    throw new Error('Run as a dedicated Viewer of the source logs');
  }
}

function sourceRoot_(props) {
  const source = driveId_(props.getProperty('LOG_SOURCE_ID'));
  const root = Drive.Files.get(source, {supportsAllDrives: true, fields: FILE_FIELDS});
  if (root.trashed || root.mimeType !== FOLDER_MIME) throw new Error('Source folder unavailable');
  requireViewer_(root);
  return source;
}

function config_() {
  const props = PropertiesService.getScriptProperties();
  const source = sourceRoot_(props);
  const output = driveId_(props.getProperty('LOG_OUTPUT_ID'));
  const item = Drive.Files.get(output, {fields: FILE_FIELDS + ',appProperties'});
  if (output === source || item.trashed || item.mimeType !== FOLDER_MIME ||
      !item.capabilities?.canAddChildren || item.appProperties?.rowingLogRole !== 'output-v1') {
    throw new Error('Invalid output folder. Run initializeLogOutput in this project.');
  }
  const pending = [...(item.parents || [])];
  const visited = new Set();
  while (pending.length) {
    const id = pending.pop();
    if (id === source) throw new Error('Output is inside the source folder');
    if (visited.has(id)) continue;
    visited.add(id);
    if (visited.size > 100) throw new Error('Unable to verify output ancestry');
    const parent = Drive.Files.get(id, {fields: 'parents,trashed'});
    if (parent.trashed) throw new Error('Output ancestor is in trash');
    pending.push(...(parent.parents || []));
  }
  return {props, source, output};
}
