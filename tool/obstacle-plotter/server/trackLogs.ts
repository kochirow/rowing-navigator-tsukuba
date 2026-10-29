import { readdir, readFile, stat } from 'node:fs/promises';
import { basename, dirname, join, relative, resolve } from 'node:path';
import type { FieldTrackDay, FieldTrackSession, FieldTrackSet } from '../src/model/fieldTracks';

/** 実機ログの保存先。リポジトリの一段上に置く運用(docs/実機ログ保存場所.md)。 */
export function defaultTrackLogRoot(repoRoot: string): string {
  return resolve(repoRoot, '..', '実機テストログデータ');
}

// 精度がこれより悪い点は、座標合わせの根拠にならないので描かない。
// 出艇前の艇庫(約7m)は残し、測位の立ち上がり(数十m)だけを落とす値。
export const maxTrackAccuracyMeters = 15;
// これより間が空いたら線を切る。途絶をまっすぐ結ぶと、通っていない水面に線が出る。
export const maxTrackGapSeconds = 10;
// 1m未満の動きは間引く。停泊中の点の山で描画が重くなるのを避ける。
export const minTrackStepMeters = 1;

const sessionFolderPattern = /^rowing_diagnostics_(.+)$/;
const maxSearchDepth = 5;

type Row = Record<string, string>;

function parseCsv(text: string): Row[] {
  const lines = text.split(/\r?\n/).filter((line) => line.length > 0);
  if (lines.length < 2) return [];
  const header = lines[0].split(',');
  // 航跡の列は数値と固定の語だけで、引用符付きの値を含まない。
  return lines.slice(1).map((line) => {
    const cells = line.split(',');
    return Object.fromEntries(header.map((name, index) => [name, cells[index] ?? '']));
  });
}

function distanceMeters(a: [number, number], b: [number, number]): number {
  const radius = 6_371_000;
  const toRad = Math.PI / 180;
  const dLat = (b[0] - a[0]) * toRad;
  const dLng = (b[1] - a[1]) * toRad;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a[0] * toRad) * Math.cos(b[0] * toRad) * Math.sin(dLng / 2) ** 2;
  return 2 * radius * Math.asin(Math.sqrt(h));
}

/** 日本時間の日付(YYYY-MM-DD)。朝練は UTC では前日になるため、必ず日本時間で区切る。 */
export function japanDate(iso: string): string {
  const time = Date.parse(iso);
  if (!Number.isFinite(time)) return 'unknown';
  return new Date(time + 9 * 3_600_000).toISOString().slice(0, 10);
}

/**
 * track.csv を、地図に描く線分の列へ変える。生の測位(raw_lat/raw_lng)を使う。
 * フィルタ後の位置は席の補正などで動くため、現地の水面を確かめる根拠にしない。
 */
export function trackSegmentsFromCsv(text: string): Array<Array<[number, number]>> {
  const segments: Array<Array<[number, number]>> = [];
  let current: Array<[number, number]> = [];
  let lastTime: number | undefined;
  const flush = () => { if (current.length > 1) segments.push(current); current = []; };
  for (const row of parseCsv(text)) {
    const lat = Number(row.raw_lat || row.filtered_lat);
    const lng = Number(row.raw_lng || row.filtered_lng);
    const accuracy = Number(row.gnss_accuracy_m);
    const time = Date.parse(row.timestamp);
    if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) continue;
    if (Number.isFinite(accuracy) && accuracy > maxTrackAccuracyMeters) { flush(); lastTime = undefined; continue; }
    if (lastTime !== undefined && Number.isFinite(time) && time - lastTime > maxTrackGapSeconds * 1000) flush();
    if (Number.isFinite(time)) lastTime = time;
    const point: [number, number] = [Number(lat.toFixed(7)), Number(lng.toFixed(7))];
    const previous = current[current.length - 1];
    if (previous && distanceMeters(previous, point) < minTrackStepMeters) continue;
    current.push(point);
  }
  flush();
  return segments;
}

async function findSessionFolders(root: string, depth = 0): Promise<string[]> {
  if (depth > maxSearchDepth) return [];
  let entries;
  try { entries = await readdir(root, { withFileTypes: true }); } catch { return []; }
  const found: string[] = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name.startsWith('.')) continue;
    const path = join(root, entry.name);
    if (sessionFolderPattern.test(entry.name)) found.push(path);
    else found.push(...await findSessionFolders(path, depth + 1));
  }
  return found;
}

/** バンドル名の先頭(例: hanazawa_rowing_diagnostics_bundle_...)を提供者名として使う。 */
function providerOf(folder: string): string | undefined {
  const parent = basename(dirname(folder));
  const match = /^(.+?)_rowing_diagnostics_bundle/.exec(parent);
  return match?.[1];
}

async function readSession(root: string, folder: string): Promise<FieldTrackSession | undefined> {
  let csv: string;
  try { csv = await readFile(join(folder, 'track.csv'), 'utf8'); } catch { return undefined; }
  let manifest: any = {};
  try { manifest = JSON.parse(await readFile(join(folder, 'manifest.json'), 'utf8')); } catch { /* 古い形式はmanifestを欠くことがある */ }
  const segments = trackSegmentsFromCsv(csv);
  if (!segments.length) return undefined;
  const id = sessionFolderPattern.exec(basename(folder))?.[1] ?? basename(folder);
  const firstTimestamp = /\n(\d{4}-\d{2}-\d{2}T[^,]+),/.exec(csv)?.[1];
  const startedAt: string = manifest.session?.startedAt ?? firstTimestamp ?? (await stat(folder)).mtime.toISOString();
  return {
    id,
    date: japanDate(startedAt),
    startedAt,
    boatType: manifest.session?.boatType,
    seatPosition: manifest.session?.seatPosition,
    appVersion: manifest.app?.version,
    provider: providerOf(folder),
    folder: relative(root, folder),
    pointCount: segments.reduce((sum, segment) => sum + segment.length, 0),
    segments,
  };
}

/**
 * 保存先の全セッションを読み、日本時間の日付ごとにまとめる。読み取り専用。
 * 同じセッションが複数のバンドルに入っている(書き出し直し)ときは、点の多いほうを残す。
 */
export async function readFieldTracks(root: string): Promise<FieldTrackSet> {
  const folders = await findSessionFolders(root);
  const byId = new Map<string, FieldTrackSession>();
  for (const folder of folders.sort()) {
    const session = await readSession(root, folder);
    if (!session) continue;
    const existing = byId.get(session.id);
    if (!existing || session.pointCount > existing.pointCount) byId.set(session.id, session);
  }
  const days = new Map<string, FieldTrackDay>();
  for (const session of [...byId.values()].sort((a, b) => a.startedAt.localeCompare(b.startedAt))) {
    const day = days.get(session.date) ?? { date: session.date, sessions: [] };
    day.sessions.push(session);
    days.set(session.date, day);
  }
  return { root, days: [...days.values()].sort((a, b) => a.date.localeCompare(b.date)) };
}
