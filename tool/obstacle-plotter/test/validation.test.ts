import { describe, expect, it } from 'vitest';
import { defaultProject, newMapObject } from '../src/model/factories';
import type { Coordinate, MapObject } from '../src/model/types';
import { validateProject } from '../src/validate/project';

const centerlinePoints: Coordinate[] = [
  { lat: 36.06, lng: 140.20 },
  { lat: 36.09, lng: 140.20 },
];

function polygon(object: MapObject, points: Coordinate[]) {
  object.geometry = { type: 'polygon', points };
  object.verificationStatus = 'field_verified';
  return object;
}

function centerline(id?: string, points = centerlinePoints) {
  const object = newMapObject('channelCenterline');
  if (id) object.exportId = id;
  object.geometry = { type: 'polyline', points };
  object.verificationStatus = 'field_verified';
  return object;
}

function lane(
  id: string,
  direction: 'along' | 'against',
  west: number,
  east: number,
  centerlineId?: string,
  south = 36.065,
  north = 36.085,
  leg?: 'outbound' | 'return',
) {
  const object = newMapObject('lane');
  object.exportId = id;
  object.laneDirection = direction;
  object.centerlineId = centerlineId;
  object.laneLeg = leg;
  return polygon(object, [
    { lat: south, lng: west }, { lat: north, lng: west },
    { lat: north, lng: east }, { lat: south, lng: east },
  ]);
}

describe('project validation', () => {
  it('blocks baked calibration until the profile version advances', () => {
    const project = defaultProject();
    project.importedFrom.profileVersion = 4;
    project.profileVersion = 4;
    project.bakedCalibration = true;
    expect(validateProject(project).some((item) => item.code === 'calibration.bake.version' && item.level === 'error')).toBe(true);
  });
  it('requires globally unique export IDs', () => {
    const project = defaultProject();
    const first = newMapObject('ashoreArea');
    const second = newMapObject('navigableWater');
    second.exportId = first.exportId;
    project.objects = [first, second];
    expect(validateProject(project).some((item) => item.code === 'object.id.duplicate')).toBe(true);
  });

  it('rejects broken folder references and parent cycles', () => {
    const project = defaultProject();
    project.folders[0].parentFolderId = project.folders[1].id;
    project.folders[1].parentFolderId = project.folders[0].id;
    const object = newMapObject('ashoreArea');
    object.parentFolderId = 'missing_folder';
    project.objects = [object];

    const codes = validateProject(project).map((item) => item.code);
    expect(codes).toContain('folder.parent.cycle');
    expect(codes).toContain('object.folder.missing');
  });

  it('requires a direction and one lane for each centerline direction', () => {
    const project = defaultProject();
    const missingDirection = lane('lane_missing', 'along', 140.201, 140.202);
    delete missingDirection.laneDirection;
    const duplicateAlong = lane('lane_also_along', 'along', 140.203, 140.204);
    const firstAlong = lane('lane_first_along', 'along', 140.205, 140.206);
    project.objects = [centerline(), missingDirection, duplicateAlong, firstAlong];
    const codes = validateProject(project).map((item) => item.code);

    expect(codes).toContain('lane.direction.missing');
    expect(codes).toContain('lane.direction.duplicate');
  });

  it('warns, but does not block, when a lane has no outbound/return', () => {
    // 往路・復路は表示専用。欠けてもアプリは無彩色の帯として描き、
    // 航行も警告も止めない。書き出しをブロックしない warning に留める。
    const project = defaultProject();
    const withoutLeg = lane('lane_no_leg', 'along', 140.201, 140.202, 'centerline_main');
    const withLeg = lane('lane_with_leg', 'against', 140.203, 140.204, 'centerline_main', 36.065, 36.085, 'return');
    project.objects = [centerline('centerline_main'), withoutLeg, withLeg];

    const issues = validateProject(project);
    const legIssues = issues.filter((item) => item.code === 'lane.leg.missing');

    expect(legIssues).toHaveLength(1);
    expect(legIssues[0].level).toBe('warning');
    expect(legIssues[0].objectId).toBe(withoutLeg.id);
    expect(issues.filter((item) => item.level === 'error' && item.code.startsWith('lane.leg'))).toEqual([]);
  });

  it('warns when the same centerline has two lanes with the same leg', () => {
    const project = defaultProject();
    project.objects = [
      centerline('centerline_main'),
      lane('lane_a', 'along', 140.201, 140.202, 'centerline_main', 36.065, 36.085, 'outbound'),
      lane('lane_b', 'against', 140.203, 140.204, 'centerline_main', 36.065, 36.085, 'outbound'),
    ];

    const duplicates = validateProject(project).filter((item) => item.code === 'lane.leg.duplicate');

    expect(duplicates).toHaveLength(2);
    expect(duplicates.every((item) => item.level === 'warning')).toBe(true);
  });

  it('does not derive the leg from the direction', () => {
    // 桜川河口の往路は direction: "against"。両者に対応関係は無い。
    const project = defaultProject();
    project.objects = [
      centerline('centerline_main'),
      lane('lane_outbound_against', 'against', 140.201, 140.202, 'centerline_main', 36.065, 36.085, 'outbound'),
      lane('lane_return_along', 'along', 140.203, 140.204, 'centerline_main', 36.065, 36.085, 'return'),
    ];

    const codes = validateProject(project).map((item) => item.code);

    expect(codes).not.toContain('lane.leg.missing');
    expect(codes).not.toContain('lane.leg.duplicate');
  });

  it('blocks overlapping lanes and lanes without a centerline', () => {
    const project = defaultProject();
    project.objects = [
      lane('lane_along', 'along', 140.201, 140.205),
      lane('lane_against', 'against', 140.204, 140.208),
    ];
    const codes = validateProject(project).map((item) => item.code);

    expect(codes).toContain('lane.overlap');
    expect(codes).toContain('centerline.missing');
    expect(validateProject(project).some((item) => item.code === 'centerline.missing' && item.level === 'error')).toBe(true);
  });

  it('allows one route lane and warns when it extends beyond centerline coverage', () => {
    const project = defaultProject();
    const outside = lane('lane_along', 'along', 140.201, 140.202);
    outside.geometry = {
      type: 'polygon',
      points: [
        { lat: 36.055, lng: 140.201 }, { lat: 36.085, lng: 140.201 },
        { lat: 36.085, lng: 140.202 }, { lat: 36.055, lng: 140.202 },
      ],
    };
    project.objects = [centerline(), outside];
    const codes = validateProject(project).map((item) => item.code);

    expect(codes).not.toContain('lane.count');
    expect(codes).toContain('lane.outside.coverage');
  });

  it('accepts six lanes with Sakuragawa guidance interrupted by transition water', () => {
    const project = defaultProject();
    const sakuragawaMouth = centerline('sakuragawa_mouth_axis', [
      { lat: 36.060, lng: 140.20 },
      { lat: 36.072, lng: 140.20 },
    ]);
    const sakuragawaUpstream = centerline('sakuragawa_upstream_axis', [
      { lat: 36.078, lng: 140.20 },
      { lat: 36.095, lng: 140.20 },
    ]);
    const kasumigaura = centerline('kasumigaura_axis', [
      { lat: 36.04, lng: 140.23 },
      { lat: 36.07, lng: 140.23 },
    ]);
    const transitionWater = polygon(newMapObject('navigableWater'), [
      { lat: 36.072, lng: 140.198 }, { lat: 36.078, lng: 140.198 },
      { lat: 36.078, lng: 140.202 }, { lat: 36.072, lng: 140.202 },
    ]);
    transitionWater.exportId = 'sakuragawa_transition_water';
    transitionWater.name = '桜川移動水域';
    project.objects = [
      sakuragawaMouth,
      sakuragawaUpstream,
      kasumigaura,
      transitionWater,
      lane('sakuragawa_mouth_outbound', 'along', 140.201, 140.202, 'sakuragawa_mouth_axis', 36.062, 36.071),
      lane('sakuragawa_mouth_return', 'against', 140.198, 140.199, 'sakuragawa_mouth_axis', 36.062, 36.071),
      lane('sakuragawa_upstream_outbound', 'along', 140.201, 140.202, 'sakuragawa_upstream_axis', 36.079, 36.092),
      lane('sakuragawa_upstream_return', 'against', 140.198, 140.199, 'sakuragawa_upstream_axis', 36.079, 36.092),
      lane('kasumigaura_outbound', 'along', 140.231, 140.232, 'kasumigaura_axis', 36.045, 36.060),
      lane('kasumigaura_return', 'against', 140.228, 140.229, 'kasumigaura_axis', 36.045, 36.060),
    ];

    const laneErrors = validateProject(project).filter((item) =>
      item.level === 'error' && item.code.startsWith('lane.'));
    expect(laneErrors).toEqual([]);
  });

  it('blocks a lane whose centerline reference is missing or unknown', () => {
    const project = defaultProject();
    project.objects = [
      centerline('sakuragawa_axis'),
      centerline('kasumigaura_axis', [
        { lat: 36.04, lng: 140.23 },
        { lat: 36.07, lng: 140.23 },
      ]),
      lane('missing_reference', 'along', 140.201, 140.202),
      lane('unknown_reference', 'against', 140.198, 140.199, 'deleted_axis'),
    ];

    const codes = validateProject(project).map((item) => item.code);
    expect(codes).toContain('lane.centerline.missing');
    expect(codes).toContain('lane.centerline.unknown');
  });

  it('warns about a reverse zone with a wide area outside both lanes', () => {
    const project = defaultProject();
    const reverse = polygon(newMapObject('reverse'), [
      { lat: 36.065, lng: 140.201 }, { lat: 36.085, lng: 140.201 },
      { lat: 36.085, lng: 140.209 }, { lat: 36.065, lng: 140.209 },
    ]);
    project.objects = [
      centerline(),
      lane('lane_along', 'along', 140.201, 140.202),
      lane('lane_against', 'against', 140.208, 140.209),
      reverse,
    ];

    expect(validateProject(project).map((item) => item.code)).toContain('lane.reverse-zone.uncovered');
  });

  it('marks legacy reverse zones disabled when linked lane guidance is available', () => {
    const project = defaultProject();
    const reverse = polygon(newMapObject('reverse'), [
      { lat: 36.065, lng: 140.198 }, { lat: 36.085, lng: 140.198 },
      { lat: 36.085, lng: 140.202 }, { lat: 36.065, lng: 140.202 },
    ]);
    project.objects = [
      centerline('sakuragawa_axis'),
      lane('lane_along', 'along', 140.201, 140.202, 'sakuragawa_axis'),
      lane('lane_against', 'against', 140.198, 140.199, 'sakuragawa_axis'),
      reverse,
    ];

    const codes = validateProject(project).map((item) => item.code);
    expect(codes).toContain('reverse.legacy.disabled');
    expect(codes).not.toContain('lane.reverse-zone.uncovered');
  });

  it('requires a valid parent bridge and keeps unplotted bridges visible as warnings', () => {
    const project = defaultProject();
    const bridge = newMapObject('bridge');
    bridge.exportId = 'bridge_main';
    bridge.geometry = { type: 'baseline', closed: true, points: [
      { lat: 36.0700, lng: 140.2000 }, { lat: 36.0703, lng: 140.2000 },
      { lat: 36.0703, lng: 140.2003 },
    ] };
    const pier = polygon(newMapObject('bridgePier'), [
      { lat: 36.0701, lng: 140.2001 }, { lat: 36.07012, lng: 140.2001 },
      { lat: 36.07012, lng: 140.20012 },
    ]);
    project.objects = [bridge, pier];
    expect(validateProject(project).map((item) => item.code)).toContain('bridgePier.bridgeId.missing');
    pier.bridgeId = bridge.exportId;
    const codes = validateProject(project).map((item) => item.code);
    expect(codes).not.toContain('bridgePier.bridgeId.missing');
    expect(codes).not.toContain('bridge.noPier');
  });

  it('warns about a bridge pier on or within 6m of the centerline without changing coordinates', () => {
    const project = defaultProject();
    const bridge = newMapObject('bridge');
    bridge.exportId = 'bridge_main';
    bridge.geometry = { type: 'baseline', closed: true, points: [
      { lat: 36.0700, lng: 140.2000 }, { lat: 36.0703, lng: 140.2000 },
      { lat: 36.0703, lng: 140.2003 },
    ] };
    const pier = polygon(newMapObject('bridgePier'), [
      { lat: 36.0749, lng: 140.19995 }, { lat: 36.0751, lng: 140.19995 },
      { lat: 36.0751, lng: 140.20005 },
    ]);
    pier.bridgeId = bridge.exportId;
    project.objects = [centerline(), bridge, pier];
    expect(validateProject(project).some((item) =>
      item.code === 'bridgePier.overlapsCenterline' && item.level === 'warning')).toBe(true);
  });
  // ---- 桟橋エリア ----
  //
  // 区域内で双方が低速なら他艇の警告音が止まる。**広すぎる区域や中心線を
  // 跨ぐ区域は、航路を通過する他艇まで静音の対象にする。** ここが安全弁。

  it('accepts a small mooring area on one side of the centerline', () => {
    const project = defaultProject();
    // 中心線は lng 140.20。岸側(西)だけを囲む約 33m × 22m。
    const area = polygon(newMapObject('mooringArea'), [
      { lat: 36.0700, lng: 140.1990 }, { lat: 36.0703, lng: 140.1990 },
      { lat: 36.0703, lng: 140.1994 }, { lat: 36.0700, lng: 140.1994 },
    ]);
    project.objects = [centerline(), area];
    const codes = validateProject(project).map((item) => item.code);
    expect(codes).not.toContain('mooringArea.tooLarge');
    expect(codes).not.toContain('mooringArea.overlapsCenterline');
    expect(codes).not.toContain('mooringArea.selfIntersection');
  });

  it('rejects a mooring area that crosses the centerline', () => {
    const project = defaultProject();
    // 中心線(lng 140.20)をまたぐ。航路上の他艇まで静音対象になる。
    const area = polygon(newMapObject('mooringArea'), [
      { lat: 36.0700, lng: 140.1998 }, { lat: 36.0703, lng: 140.1998 },
      { lat: 36.0703, lng: 140.2002 }, { lat: 36.0700, lng: 140.2002 },
    ]);
    project.objects = [centerline(), area];
    expect(validateProject(project).some((item) =>
      item.code === 'mooringArea.overlapsCenterline' && item.level === 'error')).toBe(true);
  });

  it('rejects a mooring area larger than the area limit', () => {
    const project = defaultProject();
    // 約 550m × 90m。桟橋としてあり得ない広さ。
    const area = polygon(newMapObject('mooringArea'), [
      { lat: 36.0700, lng: 140.1980 }, { lat: 36.0750, lng: 140.1980 },
      { lat: 36.0750, lng: 140.1990 }, { lat: 36.0700, lng: 140.1990 },
    ]);
    project.objects = [centerline(), area];
    expect(validateProject(project).some((item) =>
      item.code === 'mooringArea.tooLarge' && item.level === 'error')).toBe(true);
  });

  it('rejects a self-intersecting mooring area', () => {
    const project = defaultProject();
    const area = polygon(newMapObject('mooringArea'), [
      { lat: 36.0700, lng: 140.1990 }, { lat: 36.0703, lng: 140.1994 },
      { lat: 36.0703, lng: 140.1990 }, { lat: 36.0700, lng: 140.1994 },
    ]);
    project.objects = [centerline(), area];
    expect(validateProject(project).some((item) =>
      item.code === 'mooringArea.selfIntersection' && item.level === 'error')).toBe(true);
  });

  it('warns when a mooring area overlaps an ashore area', () => {
    const project = defaultProject();
    const points = [
      { lat: 36.0700, lng: 140.1990 }, { lat: 36.0703, lng: 140.1990 },
      { lat: 36.0703, lng: 140.1994 }, { lat: 36.0700, lng: 140.1994 },
    ];
    const area = polygon(newMapObject('mooringArea'), points);
    const ashore = polygon(newMapObject('ashoreArea'), points);
    project.objects = [centerline(), area, ashore];
    expect(validateProject(project).some((item) =>
      item.code === 'mooringArea.overlapsAshore' && item.level === 'warning')).toBe(true);
  });
});