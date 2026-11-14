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
