import { mkdtemp, mkdir, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { japanDate, readFieldTracks, trackSegmentsFromCsv, warningsFromEvents } from '../server/trackLogs';
import { visibleFieldTrackLines, visibleFieldTrackWarnings, warningCountsByCategory } from '../src/model/fieldTracks';

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map((path) => rm(path, { recursive: true, force: true }))); });

const header = 'timestamp,elapsed_ms,raw_lat,raw_lng,filtered_lat,filtered_lng,speed_mps,gnss_accuracy_m';
function row(second: number, lat: number, lng: number, accuracy = 2) {
  const time = new Date(Date.UTC(2026, 9, 27, 21, 0, second)).toISOString();
  return `${time},${second * 1000},${lat},${lng},${lat + 0.001},${lng},2.5,${accuracy}`;
}
function csv(rows: string[]) { return [header, ...rows].join('\n'); }

async function session(root: string, path: string, rows: string[], startedAt = '2026-10-27T21:00:00.000Z') {
  const folder = join(root, path);
  await mkdir(folder, { recursive: true });
  await writeFile(join(folder, 'track.csv'), csv(rows));
  await writeFile(join(folder, 'manifest.json'), JSON.stringify({ session: { startedAt, boatType: 'r_4p', seatPosition: 'cox' }, app: { version: '1.2.1' } }));
}

describe('実機ログの航跡', () => {
  it('朝練の日付を日本時間で数える', () => {
    expect(japanDate('2026-10-27T21:12:53.180Z')).toBe('2026-10-28');
  });

  it('生の測位を使い、精度の悪い点と途絶で線を切る', () => {
    const segments = trackSegmentsFromCsv(csv([
      row(0, 36.08, 140.21), row(1, 36.08003, 140.21), row(2, 36.08006, 140.21),
      row(3, 36.09, 140.22, 60), // 精度60m: 描かずに切る
      row(4, 36.0801, 140.21), row(5, 36.08013, 140.21),
      row(30, 36.0802, 140.21), row(31, 36.08023, 140.21), // 25秒の途絶
    ]));
    expect(segments).toEqual([
      [[36.08, 140.21], [36.08003, 140.21], [36.08006, 140.21]],
      [[36.0801, 140.21], [36.08013, 140.21]],
      [[36.0802, 140.21], [36.08023, 140.21]],
    ]);
  });

  it('1m未満の動きは間引く', () => {
    const segments = trackSegmentsFromCsv(csv([row(0, 36.08, 140.21), row(1, 36.080001, 140.21), row(2, 36.08003, 140.21)]));
    expect(segments).toEqual([[[36.08, 140.21], [36.08003, 140.21]]]);
  });

  it('保存先を日付ごとにまとめ、書き出し直した同じセッションは1本にする', async () => {
    const root = await mkdtemp(join(tmpdir(), 'field-tracks-'));
    roots.push(root);
    const track = [row(0, 36.08, 140.21), row(1, 36.08003, 140.21), row(2, 36.08006, 140.21)];
    await session(root, '2026_10/hanazawa_rowing_diagnostics_bundle_20261029-2051_1/rowing_diagnostics_111', track);
    await session(root, '2026_10/other_rowing_diagnostics_bundle_x/rowing_diagnostics_111', track.slice(0, 2));
    await session(root, '2026_08_06/rowing_diagnostics_222', track, '2026-08-05T21:16:39.956Z');
    const before = await readdir(root, { recursive: true });

    const set = await readFieldTracks(root);
    expect(set.days.map((day) => day.date)).toEqual(['2026-08-06', '2026-10-28']);
    const october = set.days[1].sessions;
    expect(october).toHaveLength(1);
    expect(october[0]).toMatchObject({ id: '111', provider: 'hanazawa', boatType: 'r_4p', pointCount: 3 });
    // 読み取り専用: 保存先へ何も足さない
    expect(await readdir(root, { recursive: true })).toEqual(before);

    const lines = visibleFieldTrackLines(set, new Set(['2026-10-28']));
    expect(lines.map((line) => line.key)).toEqual(['111:0']);
    expect(visibleFieldTrackLines(set, new Set())).toEqual([]);
  });

  it('保存先が無くても空の一覧を返す', async () => {
    const set = await readFieldTracks(join(tmpdir(), 'field-tracks-missing-folder'));
    expect(set.days).toEqual([]);
  });
  describe('鳴った警告', () => {
    const at = (second: number) => Date.UTC(2026, 9, 27, 21, 0, second);
    const event = (second: number, type: string, details: Record<string, unknown> = {}, iso = false) =>
      JSON.stringify({ seq: second, t: iso ? new Date(at(second)).toISOString() : at(second), type, details });
    const track = csv([row(0, 36.08, 140.21), row(10, 36.0801, 140.21), row(20, 36.0802, 140.21)]);

    it('再生要求だけを拾い、その時刻にいちばん近い測位に置く', () => {
      const events = [
        event(9, 'warning_presentation_requested', { category: 'other_boat', mode: 'loop' }),
        event(12, 'audio_playback_started', { asset: 'audio/other_boat_warning.mp3' }),
        event(14, 'warning_presentation_cleared', {}),
        event(19, 'warning_presentation_requested', { category: 'reverse', mode: 'playOnce' }, true),
        '{"途中で切れた行',
      ].join('\n');
      const warnings = warningsFromEvents(events, track);
      expect(warnings).toEqual([
        { at: new Date(at(9)).toISOString(), lat: 36.0801, lng: 140.21, category: 'other_boat', mode: 'loop', durationSec: 5 },
        { at: new Date(at(19)).toISOString(), lat: 36.0802, lng: 140.21, category: 'reverse', mode: 'playOnce' },
      ]);
    });

    it('測位から60秒以上離れた警告は、場所を決められないので出さない', () => {
      const events = event(200, 'warning_presentation_requested', { category: 'shore', mode: 'loop' });
      expect(warningsFromEvents(events, track)).toEqual([]);
    });

    it('名前を前に付けたセッションのフォルダも読み、名前を提供者にする', async () => {
      const root = await mkdtemp(join(tmpdir(), 'field-tracks-'));
      roots.push(root);
      await session(root, '2026_11/yamashita_rowing_diagnostics_444', [row(0, 36.08, 140.21), row(1, 36.08003, 140.21)]);
      await session(root, '2026_10/hanazawa_rowing_diagnostics_bundle_20261029-2051_1/rowing_diagnostics_555', [row(0, 36.08, 140.21), row(1, 36.08003, 140.21)]);
      const sessions = (await readFieldTracks(root)).days.flatMap((day) => day.sessions);
      expect(sessions.map((item) => [item.id, item.provider]).sort()).toEqual([['444', 'yamashita'], ['555', 'hanazawa']]);
    });

    it('セッションの読込で警告を付け、種類ごとに隠せる', async () => {
      const root = await mkdtemp(join(tmpdir(), 'field-tracks-'));
      roots.push(root);
      const folder = '2026_11/yamashita_rowing_diagnostics_bundle_x/rowing_diagnostics_333';
      await session(root, folder, [row(0, 36.08, 140.21), row(10, 36.0801, 140.21), row(20, 36.0802, 140.21)]);
      await writeFile(join(root, folder, 'events.jsonl'), [
        event(9, 'warning_presentation_requested', { category: 'other_boat', mode: 'loop' }),
        event(19, 'warning_presentation_requested', { category: 'shore', mode: 'loop' }),
      ].join('\n'));
      const set = await readFieldTracks(root);
      const dates = new Set(['2026-10-28']);
      expect(set.days[0].sessions[0].warnings).toHaveLength(2);
      expect(warningCountsByCategory(set, dates)).toEqual([['other_boat', 1], ['shore', 1]]);
      const all = visibleFieldTrackWarnings(set, dates);
      expect(all.map((marker) => marker.mark)).toEqual(['艇', '岸']);
      expect(all[0].title).toContain('他艇（繰り返し');
      expect(visibleFieldTrackWarnings(set, dates, new Set(['shore'])).map((marker) => marker.category)).toEqual(['other_boat']);
      expect(visibleFieldTrackWarnings(set, new Set())).toEqual([]);
    });
  });
});
