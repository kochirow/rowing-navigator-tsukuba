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

function centerline() {
  const object = newMapObject('channelCenterline');
  object.geometry = { type: 'polyline', points: centerlinePoints };
  object.verificationStatus = 'field_verified';
  return object;
}

function lane(id: string, direction: 'along' | 'against', west: number, east: number) {
  const object = newMapObject('lane');
  object.exportId = id;
  object.laneDirection = direction;
  return polygon(object, [
    { lat: 36.065, lng: west }, { lat: 36.085, lng: west },
    { lat: 36.085, lng: east }, { lat: 36.065, lng: east },
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

  it('warns when the lane set is incomplete or a lane extends beyond centerline coverage', () => {
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

    expect(codes).toContain('lane.count');
    expect(codes).toContain('lane.outside.coverage');
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

  it('blocks a bridge pier on or within 6m of the centerline', () => {
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
    expect(validateProject(project).map((item) => item.code)).toContain('bridgePier.overlapsCenterline');
  });
});
