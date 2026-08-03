import { defaultFolders, defaultProject, folderForKind } from '../model/factories';
import type { Coordinate, Geometry, MapObject, ObjectKind, Project } from '../model/types';
import { DANGER_BASELINE_KINDS, DANGER_POLYGON_KINDS, NAVIGABLE_KINDS } from '../model/types';
import { roundCoordinate, sameCoordinate } from './geo';

type RawItem = { id?: unknown; name?: unknown; kind?: unknown; bridgeId?: unknown; centerlineId?: unknown; direction?: unknown; leg?: unknown; warningAudio?: unknown; points?: unknown };
const knownTopLevel = new Set([
  'version', 'area', 'source', 'notice', 'howToEdit', 'defaultObstacleProximityCautionMeters',
  'practiceArea', 'operationalCoveragePolygon', 'channelCenterline', 'channelCenterlines', 'ashoreAreas', 'navigableWaters',
  'dangerZoneBaselines', 'obstacles',
]);

function asCoordinate(value: unknown): Coordinate | null {
  if (!value || typeof value !== 'object') return null;
  const point = value as Record<string, unknown>;
  return typeof point.lat === 'number' && typeof point.lng === 'number'
    ? { lat: point.lat, lng: point.lng }
    : null;
}

function pointsFrom(value: unknown): Coordinate[] {
  if (!Array.isArray(value)) return [];
  return value.map(asCoordinate).filter((point): point is Coordinate => point !== null);
}

function withoutClosingDuplicate(points: Coordinate[]): { points: Coordinate[]; closed: boolean } {
  if (points.length > 2 && sameCoordinate(points[0], points.at(-1)!)) return { points: points.slice(0, -1), closed: true };
  return { points, closed: false };
}

function kindOf(value: unknown, fallback: ObjectKind): ObjectKind {
  const all: ObjectKind[] = ['shore', 'bridge', 'bridgePier', 'island', 'driftwood', 'pile', 'testZone', 'curve', 'reverse', 'generic', 'ashoreArea', 'navigableWater', 'lane', 'channelCenterline'];
  return typeof value === 'string' && all.includes(value as ObjectKind) ? value as ObjectKind : fallback;
}

function objectFromRaw(raw: RawItem, kindFallback: ObjectKind, order: number): MapObject {
  const kind = kindOf(raw.kind, kindFallback);
  const sourcePoints = pointsFrom(raw.points);
  const baseline = DANGER_BASELINE_KINDS.has(kind);
  const closedPoints = withoutClosingDuplicate(sourcePoints);
  const geometry: Geometry = kind === 'channelCenterline'
    ? { type: 'polyline', points: sourcePoints }
    : baseline
    ? { type: 'baseline', points: closedPoints.points, closed: kind !== 'shore' || closedPoints.closed }
    : { type: 'polygon', points: sourcePoints };
  const timestamp = new Date().toISOString();
  const exportId = typeof raw.id === 'string' ? raw.id : `invalid_${order}`;
  return {
    id: `obj_profile_${exportId}`,
    exportId,
    name: typeof raw.name === 'string' ? raw.name : exportId,
    description: '',
    kind,
    ...(kind === 'lane' && (raw.direction === 'along' || raw.direction === 'against')
      ? { laneDirection: raw.direction }
      : {}),
    // 表示専用。想定外の値は落として「向きが不明」にするが、レーンは残す。
    ...(kind === 'lane' && (raw.leg === 'outbound' || raw.leg === 'return')
      ? { laneLeg: raw.leg }
      : {}),
    ...(kind === 'lane' && typeof raw.centerlineId === 'string'
      ? { centerlineId: raw.centerlineId }
      : {}),
    ...(kind === 'bridgePier' && typeof raw.bridgeId === 'string'
      ? { bridgeId: raw.bridgeId }
      : {}),
    geometry,
    warningAudio: typeof raw.warningAudio === 'string' ? raw.warningAudio : null,
    parentFolderId: folderForKind(kind),
    visible: true,
    locked: false,
    order,
    verificationStatus: kind === 'bridgePier' ? 'draft' : 'aerial_only',
    origin: { kind: 'profile' },
    style: {},
    createdAt: timestamp,
    updatedAt: timestamp,
  };
}

export async function sha256(text: string): Promise<string> {
  const hash = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(hash)].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

export async function importProfileText(text: string): Promise<Project> {
  const raw = JSON.parse(text) as Record<string, unknown>;
  const project = defaultProject();
  const version = raw.version;
  project.name = typeof raw.area === 'string' ? `${raw.area} 障害物プロジェクト` : project.name;
  project.area = typeof raw.area === 'string' ? raw.area : project.area;
  project.profileVersion = typeof version === 'number' ? version : project.profileVersion;
  project.source = typeof raw.source === 'string' ? raw.source : '';
  project.notice = typeof raw.notice === 'string' ? raw.notice : '';
  project.howToEdit = typeof raw.howToEdit === 'string' ? raw.howToEdit : '';
  project.defaultObstacleProximityCautionMeters = typeof raw.defaultObstacleProximityCautionMeters === 'number'
    ? raw.defaultObstacleProximityCautionMeters : 0;
  project.importedFrom.profileSha256 = await sha256(text);
  project.importedFrom.profileVersion = project.profileVersion;
  project.profileExtras = Object.fromEntries(Object.entries(raw).filter(([key]) => !knownTopLevel.has(key)));
  project.specialFieldExtras = Object.fromEntries(['practiceArea', 'operationalCoveragePolygon', 'channelCenterline'].flatMap((field) => {
    const value = raw[field] as Record<string, unknown> | undefined;
    if (!value || typeof value !== 'object') return [];
    return [[field, Object.fromEntries(Object.entries(value).filter(([key]) => key !== 'name' && key !== 'points'))]];
  }));
  const objects: MapObject[] = [];
  for (const [index, item] of (Array.isArray(raw.dangerZoneBaselines) ? raw.dangerZoneBaselines : []).entries()) {
    objects.push(objectFromRaw(item as RawItem, 'shore', index));
  }
  for (const [index, item] of (Array.isArray(raw.obstacles) ? raw.obstacles : []).entries()) {
    objects.push(objectFromRaw(item as RawItem, 'generic', index));
  }
  for (const [index, item] of (Array.isArray(raw.ashoreAreas) ? raw.ashoreAreas : []).entries()) {
    objects.push(objectFromRaw(item as RawItem, 'ashoreArea', index));
  }
  for (const [index, item] of (Array.isArray(raw.navigableWaters) ? raw.navigableWaters : []).entries()) {
    objects.push(objectFromRaw(item as RawItem, 'navigableWater', index));
  }
  const explicitCenterlines = Array.isArray(raw.channelCenterlines) ? raw.channelCenterlines : [];
  for (const [index, item] of explicitCenterlines.entries()) {
    objects.push(objectFromRaw(item as RawItem, 'channelCenterline', index));
  }
  const special = (field: 'practiceArea' | 'operationalCoveragePolygon' | 'channelCenterline', kind: ObjectKind, exportId: string, geometryType: 'polygon' | 'polyline') => {
    const value = raw[field] as Record<string, unknown> | undefined;
    const points = pointsFrom(value?.points);
    if (points.length === 0) return;
    const timestamp = new Date().toISOString();
    objects.push({
      id: `obj_profile_${kind}`, exportId, name: typeof value?.name === 'string' ? value.name : kind,
      description: '', kind, geometry: { type: geometryType, points }, warningAudio: null,
      parentFolderId: 'fld_safety', visible: true, locked: false, order: -1,
      verificationStatus: 'aerial_only', origin: { kind: 'profile' }, style: {}, createdAt: timestamp, updatedAt: timestamp,
    });
  };
  special('practiceArea', 'practiceArea', 'practice_area', 'polygon');
  special('operationalCoveragePolygon', 'operationalCoverage', 'operational_coverage', 'polygon');
  if (explicitCenterlines.length === 0) {
    special('channelCenterline', 'channelCenterline', 'channel_centerline', 'polyline');
  }
  project.folders = defaultFolders();
  project.objects = objects;
  project.selectedObjectId = objects[0]?.id ?? null;
  return project;
}

function profilePoints(geometry: Geometry): Coordinate[] {
  if (geometry.type === 'point') return [roundCoordinate(geometry.point)];
  const rounded = geometry.points.map(roundCoordinate);
  return geometry.type === 'baseline' && geometry.closed && rounded.length > 0 ? [...rounded, rounded[0]] : rounded;
}

function standardItem(object: MapObject) {
  return {
    id: object.exportId,
    name: object.name,
    kind: object.kind,
    // 同梱プロファイルと同じ並び（kind → leg → direction）を保つ。
    // 並びが変わるとファイルの SHA-256 が変わり、firestore.rules に
    // 固定された baseProfileSha256 との突き合わせが不必要に外れる。
    ...(object.kind === 'lane' && object.laneLeg
      ? { leg: object.laneLeg }
      : {}),
    ...(object.kind === 'lane' && object.laneDirection
      ? { direction: object.laneDirection }
      : {}),
    ...(object.kind === 'lane' && object.centerlineId
      ? { centerlineId: object.centerlineId }
      : {}),
    ...(object.kind === 'bridgePier' && object.bridgeId
      ? { bridgeId: object.bridgeId }
      : {}),
    ...(object.warningAudio ? { warningAudio: object.warningAudio } : {}),
    points: profilePoints(object.geometry),
  };
}

export function profileObject(project: Project): Record<string, unknown> {
  const byKind = (predicate: (object: MapObject) => boolean) => project.objects.filter(predicate).sort((a, b) => a.order - b.order);
  const singleton = (kind: ObjectKind) => project.objects.find((object) => object.kind === kind);
  const output: Record<string, unknown> = {
    version: project.profileVersion,
    area: project.area,
    source: project.source,
    notice: project.notice,
    howToEdit: project.howToEdit,
    defaultObstacleProximityCautionMeters: project.defaultObstacleProximityCautionMeters,
  };
  const practice = singleton('practiceArea');
  if (practice) output.practiceArea = { ...(project.specialFieldExtras?.practiceArea ?? {}), name: practice.name, points: profilePoints(practice.geometry) };
  const coverage = singleton('operationalCoverage');
  if (coverage) output.operationalCoveragePolygon = { ...(project.specialFieldExtras?.operationalCoveragePolygon ?? {}), name: coverage.name, points: profilePoints(coverage.geometry) };
  const centerlines = byKind((object) => object.kind === 'channelCenterline');
  if (centerlines.length > 0) {
    output.channelCenterlines = centerlines.map(standardItem);
    // 単一中心線は旧アプリでも使えるよう、従来フィールドも併記する。
    // 複数時に1本だけを併記すると旧版が別水域へ誤投影するため出力しない。
    if (centerlines.length === 1) {
      output.channelCenterline = {
        ...(project.specialFieldExtras?.channelCenterline ?? {}),
        id: centerlines[0].exportId,
        name: centerlines[0].name,
        points: profilePoints(centerlines[0].geometry),
      };
    }
  }
  output.ashoreAreas = byKind((object) => object.kind === 'ashoreArea').map(standardItem);
  output.navigableWaters = byKind((object) => NAVIGABLE_KINDS.has(object.kind)).map(standardItem);
  output.dangerZoneBaselines = byKind((object) => DANGER_BASELINE_KINDS.has(object.kind)).map(standardItem);
  output.obstacles = byKind((object) => DANGER_POLYGON_KINDS.has(object.kind)).map(standardItem);
  return { ...project.profileExtras, ...output };
}

export function exportProfileText(project: Project): string {
  return `${JSON.stringify(profileObject(project), null, 2)}\n`;
}
