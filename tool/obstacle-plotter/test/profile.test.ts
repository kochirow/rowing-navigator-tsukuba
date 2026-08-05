import { readFile } from 'node:fs/promises';
import { describe, expect, it } from 'vitest';
import { exportProfileText, importProfileText } from '../src/io/profile';
import { validateProject } from '../src/validate/project';

const source = JSON.stringify({
  version: 4,
  area: '桜川（茨城県土浦市）',
  source: 'fixture',
  notice: 'fixture',
  howToEdit: 'fixture',
  defaultObstacleProximityCautionMeters: 0,
  channelCenterline: { points: [{ lat: 36.07, lng: 140.19 }, { lat: 36.071, lng: 140.191 }] },
  ashoreAreas: [{ id: 'ashore_boathouse', name: '艇庫前', kind: 'ashoreArea', points: [{ lat: 36.07, lng: 140.19 }, { lat: 36.071, lng: 140.19 }, { lat: 36.071, lng: 140.191 }] }],
  navigableWaters: [
    { id: 'water_main', name: '水面', kind: 'navigableWater', points: [{ lat: 36.07, lng: 140.19 }, { lat: 36.071, lng: 140.19 }, { lat: 36.071, lng: 140.191 }] },
    { id: 'lane_along', name: '往路', kind: 'lane', leg: 'outbound', direction: 'along', points: [{ lat: 36.07, lng: 140.191 }, { lat: 36.071, lng: 140.191 }, { lat: 36.071, lng: 140.192 }] },
  ],
  dangerZoneBaselines: [{ id: 'shore_north', name: '北岸', kind: 'shore', points: [{ lat: 36.07, lng: 140.19 }, { lat: 36.071, lng: 140.191 }] }, { id: 'bridge_a', name: '橋', kind: 'bridge', points: [{ lat: 36.07, lng: 140.19 }, { lat: 36.071, lng: 140.19 }, { lat: 36.071, lng: 140.191 }, { lat: 36.07, lng: 140.19 }] }],
  obstacles: [
    { id: 'curve_1', name: 'カーブ', kind: 'curve', points: [{ lat: 36.07, lng: 140.19 }, { lat: 36.071, lng: 140.19 }, { lat: 36.071, lng: 140.191 }] },
    { id: 'bridgepier_a_1', name: '橋脚1', kind: 'bridgePier', bridgeId: 'bridge_a', points: [{ lat: 36.07010, lng: 140.19010 }, { lat: 36.07020, lng: 140.19008 }, { lat: 36.07025, lng: 140.19016 }, { lat: 36.07018, lng: 140.19024 }, { lat: 36.07008, lng: 140.19020 }] },
    { id: 'pile_a_1', name: '杭1', kind: 'pile', points: [{ lat: 36.07030, lng: 140.19030 }, { lat: 36.07031, lng: 140.19030 }, { lat: 36.07031, lng: 140.19031 }, { lat: 36.07030, lng: 140.19031 }] },
  ],
});

describe('profile IO', () => {
  it('accepts the bundled profile without geometry or area-range errors', async () => {
    const profile = await importProfileText(
      await readFile('../../assets/data/sakuragawa_obstacles.json', 'utf8'),
    );
    const issues = validateProject(profile);
    expect(issues.filter((item) => item.level === 'error')).toEqual([]);
    expect(
      issues.filter((item) =>
        item.code === 'object.point.sakuragawa-range' ||
        item.code === 'object.point.near-duplicate'),
    ).toEqual([]);
  });

  it('keeps safety data out of danger-zone arrays and restores direct bridge-pier outer polygons', async () => {
    const project = await importProfileText(source);
    const bridge = project.objects.find((object) => object.exportId === 'bridge_a')!;
    expect(bridge.geometry.type).toBe('baseline');
    expect(bridge.geometry.type === 'baseline' && bridge.geometry.points).toHaveLength(3);
    expect(bridge.geometry.type === 'baseline' && bridge.geometry.closed).toBe(true);
    const output = JSON.parse(exportProfileText(project));
    expect(output.ashoreAreas.map((item: { id: string }) => item.id)).toEqual(['ashore_boathouse']);
    expect(output.navigableWaters.map((item: { id: string }) => item.id)).toEqual(['water_main', 'lane_along']);
    expect(output.navigableWaters[1].direction).toBe('along');
    expect(output.navigableWaters[1].leg).toBe('outbound');
    expect(output.channelCenterlines).toHaveLength(1);
    expect(output.channelCenterlines[0].id).toBe('channel_centerline');
    expect(output.channelCenterline.id).toBe('channel_centerline');
    expect(output.dangerZoneBaselines.map((item: { id: string }) => item.id)).toEqual(['shore_north', 'bridge_a']);
    expect(output.obstacles.map((item: { id: string }) => item.id)).toEqual(['curve_1', 'bridgepier_a_1', 'pile_a_1']);
    expect(output.obstacles[1].kind).toBe('bridgePier');
    expect(output.obstacles[1].bridgeId).toBe('bridge_a');
    expect(output.obstacles[1].points).toHaveLength(5);
    expect(output.obstacles[2].kind).toBe('pile');
    expect(output.obstacles[2].points).toHaveLength(4);
    expect(output.dangerZoneBaselines[1].points).toHaveLength(4);
  });

  it('round-trips multiple centerlines and each lane reference without emitting a misleading legacy singleton', async () => {
    const profile = {
      ...JSON.parse(source),
      channelCenterline: undefined,
      channelCenterlines: [
        { id: 'kasumigaura_axis', name: '霞ヶ浦中心線', kind: 'channelCenterline', points: [{ lat: 36.05, lng: 140.20 }, { lat: 36.06, lng: 140.21 }] },
        { id: 'sakuragawa_axis', name: '桜川中心線', kind: 'channelCenterline', points: [{ lat: 36.07, lng: 140.19 }, { lat: 36.08, lng: 140.20 }] },
      ],
      navigableWaters: [
        { id: 'kasumigaura_outbound', name: '霞ヶ浦往路', kind: 'lane', centerlineId: 'kasumigaura_axis', direction: 'along', points: [{ lat: 36.05, lng: 140.20 }, { lat: 36.051, lng: 140.20 }, { lat: 36.051, lng: 140.201 }] },
        { id: 'sakuragawa_return', name: '桜川復路', kind: 'lane', centerlineId: 'sakuragawa_axis', direction: 'against', points: [{ lat: 36.07, lng: 140.19 }, { lat: 36.071, lng: 140.19 }, { lat: 36.071, lng: 140.191 }] },
      ],
    };

    const project = await importProfileText(JSON.stringify(profile));
    const output = JSON.parse(exportProfileText(project));

    expect(output.channelCenterlines.map((item: { id: string }) => item.id))
      .toEqual(['kasumigaura_axis', 'sakuragawa_axis']);
    expect(output.navigableWaters.map((item: { centerlineId: string }) => item.centerlineId))
      .toEqual(['kasumigaura_axis', 'sakuragawa_axis']);
    expect(output.channelCenterline).toBeUndefined();
  });

  it('gives special singletons lowercase internal IDs that pass validation', async () => {
    const project = await importProfileText(JSON.stringify({
      ...JSON.parse(source),
      practiceArea: { name: '練習水域', memo: '既存メモ', points: [{ lat: 36.07, lng: 140.19 }, { lat: 36.071, lng: 140.19 }, { lat: 36.071, lng: 140.191 }] },
      operationalCoveragePolygon: { name: '対応水域', memo: '対応水域メモ', points: [{ lat: 36.07, lng: 140.19 }, { lat: 36.071, lng: 140.19 }, { lat: 36.071, lng: 140.191 }] },
    }));
    expect(project.objects.find((object) => object.kind === 'practiceArea')?.exportId).toBe('practice_area');
    expect(project.objects.find((object) => object.kind === 'operationalCoverage')?.exportId).toBe('operational_coverage');
    expect(validateProject(project).filter((item) => item.code === 'object.id')).toEqual([]);
    const output = JSON.parse(exportProfileText(project));
    expect(output.practiceArea.memo).toBe('既存メモ');
    expect(output.operationalCoveragePolygon.memo).toBe('対応水域メモ');
  });

  it('round-trips the bundled profile byte-for-byte, keeping every lane leg', async () => {
    // **この作業のいちばんの目的。** 作図ツールが `leg` を知らなかった頃は、
    // 書き出し直すだけで往路・復路の指定が黙って消えていた。消えても
    // アプリは無彩色の帯を描いて航行を続ける（原則1）ため、現地で
    // 「色が付かない」と気づくまで分からない。ここで固定しておく。
    const text = await readFile('../../assets/data/sakuragawa_obstacles.json', 'utf8');
    const project = await importProfileText(text);
    const exported = exportProfileText(project);

    // フィールドの並びまで含めて一致すること。並びが変われば SHA-256 が
    // 変わり、firestore.rules に固定した baseProfileSha256 と食い違う。
    expect(exported).toBe(text);

    const lanes = JSON.parse(exported).navigableWaters
      .filter((item: { kind: string }) => item.kind === 'lane');
    expect(lanes.length).toBeGreaterThan(0);
    for (const lane of lanes) {
      expect(['outbound', 'return']).toContain(lane.leg);
    }
  });

  it('keeps the leg independent from the direction', async () => {
    // `direction` は中心線の頂点順に対する内部量で、往路・復路とは無関係。
    // 実データでも桜川河口の往路は direction: "against" になっている。
    // 片方から他方を導ける実装に戻ったら、ここで落ちる。
    const project = await importProfileText(
      await readFile('../../assets/data/sakuragawa_obstacles.json', 'utf8'),
    );
    const lanes = project.objects.filter((object) => object.kind === 'lane');
    const outboundDirections = new Set(
      lanes.filter((lane) => lane.laneLeg === 'outbound').map((lane) => lane.laneDirection),
    );

    expect(outboundDirections.size).toBeGreaterThan(1);
  });

  it('drops an unknown leg without dropping the lane', async () => {
    const profile = JSON.parse(source);
    profile.navigableWaters[1].leg = 'FOO';
    const project = await importProfileText(JSON.stringify(profile));

    const lane = project.objects.find((object) => object.exportId === 'lane_along')!;
    expect(lane.laneLeg).toBeUndefined();
    expect(lane.laneDirection).toBe('along');

    const output = JSON.parse(exportProfileText(project));
    expect(output.navigableWaters.map((item: { id: string }) => item.id)).toContain('lane_along');
    expect(output.navigableWaters[1].leg).toBeUndefined();
  });
  it('round-trips mooring areas and omits the field when none are plotted', async () => {
    // 桟橋エリアが無いプロファイルへ空配列を足すと、JSONのバイト列が変わり
    // firestore.rules に固定した SHA-256 と食い違う。1件以上あるときだけ出す。
    const withoutMooring = await importProfileText(source);
    expect(JSON.parse(exportProfileText(withoutMooring)).mooringAreas).toBeUndefined();

    const withMooring = JSON.parse(source);
    withMooring.mooringAreas = [{
      id: 'mooring_boathouse', name: '艇庫前桟橋', kind: 'mooringArea',
      points: [{ lat: 36.07, lng: 140.192 }, { lat: 36.071, lng: 140.192 }, { lat: 36.071, lng: 140.193 }],
    }];
    const project = await importProfileText(JSON.stringify(withMooring, null, 2));
    const area = project.objects.find((object) => object.exportId === 'mooring_boathouse')!;
    expect(area.kind).toBe('mooringArea');
    const output = JSON.parse(exportProfileText(project));
    expect(output.mooringAreas.map((item: { id: string }) => item.id)).toEqual(['mooring_boathouse']);
    // 危険区域の配列へ混ざらないこと。
    expect(output.dangerZoneBaselines.map((item: { id: string }) => item.id)).not.toContain('mooring_boathouse');
    expect(output.obstacles.map((item: { id: string }) => item.id)).not.toContain('mooring_boathouse');
  });
});