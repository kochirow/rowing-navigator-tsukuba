import type { Coordinate, Folder, Geometry, MapObject, ObjectKind, Project } from './types';

const now = () => new Date().toISOString();
const uuid = () => crypto.randomUUID();

export function defaultProject(): Project {
  const createdAt = now();
  return {
    schemaVersion: 4,
    id: `proj_${uuid()}`,
    name: '桜川障害物プロジェクト',
    area: '桜川（茨城県土浦市）',
    profileVersion: 8,
    source: '',
    notice: '',
    howToEdit: '',
    defaultObstacleProximityCautionMeters: 0,
    importedFrom: {
      profileSha256: null, profileVersion: null, calibrationRevision: null,
      calibrationFetchedAt: null, temporaryFetchedAt: null, teamId: null,
    },
    folders: defaultFolders(),
    objects: [],
    camera: { center: { lat: 36.078294, lng: 140.195898 }, distance: 1500 },
    selectedObjectId: null,
    createdAt,
    updatedAt: createdAt,
    profileExtras: {},
    specialFieldExtras: {},
    bakedCalibration: false,
  };
}

export function defaultFolders(): Folder[] {
  return [
    ['fld_banks', '河岸'], ['fld_bridges', '橋'], ['fld_islands', '中州'],
    ['fld_driftwood', '流木'], ['fld_piles', '杭'], ['fld_curve', 'カーブ'], ['fld_reverse', '逆走注意'],
    ['fld_test', 'テスト区域'], ['fld_mooring', '桟橋エリア'], ['fld_safety', '安全データ'], ['fld_imported', '臨時（取込）'],
  ].map(([id, name], order) => ({ id, name, parentFolderId: null, expanded: true, visible: true, locked: false, order }));
}

export function newFolder(name: string, parentFolderId: string | null, order: number): Folder {
  return {
    id: `fld_${uuid()}`,
    name,
    parentFolderId,
    expanded: true,
    visible: true,
    locked: false,
    order,
  };
}

export function geometryForKind(kind: ObjectKind): Geometry {
  if (kind === 'shore') return { type: 'baseline', points: [], closed: false };
  if (['bridge', 'island', 'driftwood', 'testZone'].includes(kind)) {
    return { type: 'baseline', points: [], closed: true };
  }
  if (kind === 'channelCenterline') return { type: 'polyline', points: [] };
  return { type: 'polygon', points: [] };
}

export function newMapObject(kind: ObjectKind, coordinate?: Coordinate): MapObject {
  const timestamp = now();
  const geometry = geometryForKind(kind);
  if (coordinate && geometry.type !== 'point') geometry.points = [coordinate];
  return {
    id: `obj_${uuid()}`,
    exportId: `${kind === 'bridgePier' ? 'bridgepier' : kind.toLowerCase()}_${uuid().slice(0, 8)}`,
    name: kind,
    description: '',
    kind,
    ...(kind === 'lane' ? { laneDirection: 'along' as const } : {}),
    geometry,
    warningAudio: null,
    parentFolderId: folderForKind(kind),
    visible: true,
    locked: false,
    order: Date.now(),
    verificationStatus: 'draft',
    origin: { kind: 'drawn' },
    style: {},
    createdAt: timestamp,
    updatedAt: timestamp,
  };
}

export function folderForKind(kind: ObjectKind): string {
  if (kind === 'shore') return 'fld_banks';
  if (kind === 'bridge' || kind === 'bridgePier') return 'fld_bridges';
  if (kind === 'island') return 'fld_islands';
  if (kind === 'driftwood') return 'fld_driftwood';
  if (kind === 'pile') return 'fld_piles';
  if (kind === 'curve') return 'fld_curve';
  if (kind === 'reverse') return 'fld_reverse';
  if (kind === 'testZone') return 'fld_test';
  if (kind === 'mooringArea') return 'fld_mooring';
  return 'fld_safety';
}
