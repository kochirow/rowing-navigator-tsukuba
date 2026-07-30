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
    { id: 'lane_along', name: '往路', kind: 'lane', direction: 'along', points: [{ lat: 36.07, lng: 140.191 }, { lat: 36.071, lng: 140.191 }, { lat: 36.071, lng: 140.192 }] },
  ],
  dangerZoneBaselines: [{ id: 'shore_north', name: '北岸', kind: 'shore', points: [{ lat: 36.07, lng: 140.19 }, { lat: 36.071, lng: 140.191 }] }, { id: 'bridge_a', name: '橋', kind: 'bridge', points: [{ lat: 36.07, lng: 140.19 }, { lat: 36.071, lng: 140.19 }, { lat: 36.071, lng: 140.191 }, { lat: 36.07, lng: 140.19 }] }],
  obstacles: [
    { id: 'curve_1', name: 'カーブ', kind: 'curve', points: [{ lat: 36.07, lng: 140.19 }, { lat: 36.071, lng: 140.19 }, { lat: 36.071, lng: 140.191 }] },
    { id: 'bridgepier_a_1', name: '橋脚1', kind: 'bridgePier', bridgeId: 'bridge_a', points: [{ lat: 36.0701, lng: 140.1901 }, { lat: 36.0702, lng: 140.1901 }, { lat: 36.0702, lng: 140.1902 }] },
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

  it('keeps safety data out of danger-zone arrays and restores closed baselines', async () => {
    const project = await importProfileText(source);
    const bridge = project.objects.find((object) => object.exportId === 'bridge_a')!;
    expect(bridge.geometry.type).toBe('baseline');
    expect(bridge.geometry.type === 'baseline' && bridge.geometry.points).toHaveLength(3);
    expect(bridge.geometry.type === 'baseline' && bridge.geometry.closed).toBe(true);
    const output = JSON.parse(exportProfileText(project));
    expect(output.ashoreAreas.map((item: { id: string }) => item.id)).toEqual(['ashore_boathouse']);
    expect(output.navigableWaters.map((item: { id: string }) => item.id)).toEqual(['water_main', 'lane_along']);
    expect(output.navigableWaters[1].direction).toBe('along');
    expect(output.dangerZoneBaselines.map((item: { id: string }) => item.id)).toEqual(['shore_north', 'bridge_a']);
    expect(output.obstacles.map((item: { id: string }) => item.id)).toEqual(['curve_1', 'bridgepier_a_1']);
    expect(output.obstacles[1].kind).toBe('bridgePier');
    expect(output.obstacles[1].bridgeId).toBe('bridge_a');
    expect(output.dangerZoneBaselines[1].points).toHaveLength(4);
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
});
