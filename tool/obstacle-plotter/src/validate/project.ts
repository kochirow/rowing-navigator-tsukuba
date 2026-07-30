import { distanceMeters, distancePointToSegmentMeters, hasSelfIntersection, pointInPolygon, polygonsOverlap, segmentsIntersect } from '../io/geo';
import type { Geometry, MapObject, Project, ValidationIssue } from '../model/types';
import { DANGER_BASELINE_KINDS, DANGER_POLYGON_KINDS, NAVIGABLE_KINDS, SINGLETON_KINDS } from '../model/types';

function pointsOf(geometry: Geometry) {
  return geometry.type === 'point' ? [geometry.point] : geometry.points;
}

function issue(level: ValidationIssue['level'], code: string, message: string, object?: MapObject): ValidationIssue {
  return { level, code, message, objectId: object?.id };
}

function polygonPoints(object: MapObject) {
  return object.geometry.type === 'polygon' ? object.geometry.points : [];
}

function centroid(points: { lat: number; lng: number }[]) {
  return points.reduce(
    (total, point) => ({ lat: total.lat + point.lat / points.length, lng: total.lng + point.lng / points.length }),
    { lat: 0, lng: 0 },
  );
}

function dimensionsMeters(points: { lat: number; lng: number }[]) {
  const center = centroid(points);
  const eastScale = Math.cos(center.lat * Math.PI / 180) * 111_320;
  const northScale = 110_540;
  const east = points.map((point) => (point.lng - center.lng) * eastScale);
  const north = points.map((point) => (point.lat - center.lat) * northScale);
  const width = Math.max(...east) - Math.min(...east);
  const height = Math.max(...north) - Math.min(...north);
  return { long: Math.max(width, height), short: Math.min(width, height) };
}

function centerlineTouchesOrNearPolygon(
  centerline: { lat: number; lng: number }[],
  polygon: { lat: number; lng: number }[],
  marginMeters: number,
) {
  for (let index = 0; index < centerline.length - 1; index += 1) {
    const start = centerline[index];
    const end = centerline[index + 1];
    if (pointInPolygon(start, polygon) || pointInPolygon(end, polygon)) return true;
    for (let edge = 0; edge < polygon.length; edge += 1) {
      const first = polygon[edge];
      const second = polygon[(edge + 1) % polygon.length];
      if (segmentsIntersect(start, end, first, second)) return true;
      if (distancePointToSegmentMeters(first, start, end) <= marginMeters ||
          distancePointToSegmentMeters(start, first, second) <= marginMeters ||
          distancePointToSegmentMeters(end, first, second) <= marginMeters) return true;
    }
  }
  return false;
}

/// `ChannelCenterline.project()` と同じ意味の、端点から外側へはみ出して
/// いないかだけを判定する。横方向の距離には制限を設けない。
function isInsideCenterlineCoverage(point: { lat: number; lng: number }, centerline: { lat: number; lng: number }[]) {
  for (let index = 0; index < centerline.length - 1; index += 1) {
    const start = centerline[index];
    const end = centerline[index + 1];
    const eastScale = Math.cos(point.lat * Math.PI / 180);
    const deltaEast = (end.lng - start.lng) * eastScale;
    const deltaNorth = end.lat - start.lat;
    const lengthSquared = deltaEast * deltaEast + deltaNorth * deltaNorth;
    if (lengthSquared <= 1e-15) continue;
    const pointEast = (point.lng - start.lng) * eastScale;
    const pointNorth = point.lat - start.lat;
    const ratio = (pointEast * deltaEast + pointNorth * deltaNorth) / lengthSquared;
    if (ratio >= 0 && ratio <= 1) return true;
  }
  return false;
}

function distanceToPolygonBoundary(point: { lat: number; lng: number }, polygon: { lat: number; lng: number }[]) {
  let minimum = Number.POSITIVE_INFINITY;
  for (let index = 0; index < polygon.length; index += 1) {
    minimum = Math.min(minimum, distancePointToSegmentMeters(point, polygon[index], polygon[(index + 1) % polygon.length]));
  }
  return minimum;
}

function reverseZoneSamples(points: { lat: number; lng: number }[]) {
  const samples = [...points];
  const center = points.reduce((total, point) => ({ lat: total.lat + point.lat / points.length, lng: total.lng + point.lng / points.length }), { lat: 0, lng: 0 });
  samples.push(center);
  const latitudes = points.map((point) => point.lat);
  const longitudes = points.map((point) => point.lng);
  const minimumLat = Math.min(...latitudes);
  const maximumLat = Math.max(...latitudes);
  const minimumLng = Math.min(...longitudes);
  const maximumLng = Math.max(...longitudes);
  // 10m前後の格子。最大441点に抑え、作図中の検証を重くしない。
  const latStep = Math.max((maximumLat - minimumLat) / 20, 0.00009);
  const lngStep = Math.max((maximumLng - minimumLng) / 20, 0.00011);
  for (let lat = minimumLat + latStep / 2; lat < maximumLat && samples.length < 450; lat += latStep) {
    for (let lng = minimumLng + lngStep / 2; lng < maximumLng && samples.length < 450; lng += lngStep) {
      const point = { lat, lng };
      if (pointInPolygon(point, points)) samples.push(point);
    }
  }
  return samples;
}

export function validateProject(project: Project): ValidationIssue[] {
  const issues: ValidationIssue[] = [];
  if (!Number.isInteger(project.profileVersion)) issues.push(issue('error', 'profile.version', 'version は整数でなければなりません。'));
  if (!project.area.trim()) issues.push(issue('error', 'profile.area', 'area は空にできません。'));
  if (!Number.isFinite(project.defaultObstacleProximityCautionMeters) || project.defaultObstacleProximityCautionMeters < 0) {
    issues.push(issue('error', 'profile.proximity', '既定の近接注意距離が不正です。'));
  }
  const foldersById = new Map(project.folders.map((folder) => [folder.id, folder]));
  for (const folder of project.folders) {
    if (!folder.name.trim()) issues.push(issue('error', 'folder.name', 'フォルダ名は空にできません。'));
    if (folder.parentFolderId && !foldersById.has(folder.parentFolderId)) {
      issues.push(issue('error', 'folder.parent.missing', `フォルダ「${folder.name}」の親フォルダが見つかりません。`));
    }
    const ancestors = new Set<string>([folder.id]);
    let parentId = folder.parentFolderId;
    while (parentId) {
      if (ancestors.has(parentId)) {
        issues.push(issue('error', 'folder.parent.cycle', `フォルダ「${folder.name}」の親子関係が循環しています。`));
        break;
      }
      ancestors.add(parentId);
      parentId = foldersById.get(parentId)?.parentFolderId ?? null;
    }
  }
  const exportIds = new Set<string>();
  const singletonCounts = new Map<string, number>();
  for (const object of project.objects) {
    const points = pointsOf(object.geometry);
    if (object.parentFolderId && !foldersById.has(object.parentFolderId)) {
      issues.push(issue('error', 'object.folder.missing', `「${object.name || object.exportId}」のフォルダが見つかりません。`, object));
    }
    const minimum = object.geometry.type === 'baseline' || object.geometry.type === 'polyline' ? 2 : 3;
    if (!object.exportId || object.exportId.length > 128 || !/^[a-z0-9_]+$/.test(object.exportId)) {
      issues.push(issue('error', 'object.id', 'exportId は128文字以下の英小文字・数字・_で指定してください。', object));
    } else if (exportIds.has(object.exportId)) {
      issues.push(issue('error', 'object.id.duplicate', `exportId ${object.exportId} が重複しています。`, object));
    } else exportIds.add(object.exportId);
    if (points.length < minimum || points.length > 1000) {
      issues.push(issue('error', 'object.points.count', `頂点数は ${minimum}〜1000 点である必要があります。`, object));
    }
    for (const [index, point] of points.entries()) {
      if (!Number.isFinite(point.lat) || !Number.isFinite(point.lng) || point.lat < -90 || point.lat > 90 || point.lng < -180 || point.lng > 180) {
        issues.push(issue('error', 'object.point.range', `頂点 ${index + 1} の座標が範囲外です。`, object));
      }
      if (point.lat < 36.05 || point.lat > 36.10 || point.lng < 140.09 || point.lng > 140.26) {
        issues.push(issue('warning', 'object.point.sakuragawa-range', `頂点 ${index + 1} が桜川・霞ヶ浦の確認範囲外です。`, object));
      }
    }
    if (object.geometry.type === 'polygon' && points.length >= 4 && hasSelfIntersection(points)) {
      issues.push(issue('error', 'object.polygon.self-intersection', 'ポリゴンが自己交差しています。', object));
    }
    if (object.geometry.type === 'baseline' && object.kind !== 'shore' && !object.geometry.closed) {
      issues.push(issue('warning', 'baseline.open', 'この基準線は閉じる必要があります。書き出し時に自動で閉じます。', object));
    }
    if (object.kind === 'shore' && object.geometry.type !== 'baseline') {
      issues.push(issue('error', 'shore.geometry', '岸は向きを持つ基準線でなければなりません。', object));
    }
    if (object.kind === 'channelCenterline' && object.geometry.type !== 'polyline') {
      issues.push(issue('error', 'centerline.geometry', '航路中心線は折れ線でなければなりません。', object));
    }
    if (SINGLETON_KINDS.has(object.kind)) singletonCounts.set(object.kind, (singletonCounts.get(object.kind) ?? 0) + 1);
    if (object.verificationStatus === 'draft') issues.push(issue('warning', 'object.draft', '確認状況が draft のオブジェクトがあります。', object));
    for (let index = 1; index < points.length; index += 1) {
      if (distanceMeters(points[index - 1], points[index]) < 0.3) {
        issues.push(issue('warning', 'object.point.near-duplicate', '0.3m未満の隣接頂点があります。', object));
        break;
      }
    }
  }
  for (const [kind, count] of singletonCounts) {
    if (count > 1) issues.push(issue('error', 'singleton.duplicate', `${kind} は1つだけ作成できます。`));
  }
  if (!project.objects.some((object) => object.kind === 'ashoreArea')) {
    issues.push(issue('warning', 'ashore.missing', '陸上エリアがありません。アプリは安全側として音を止めません。'));
  }
  const lanes = project.objects.filter((object) => object.kind === 'lane');
  const centerline = project.objects.find((object) => object.kind === 'channelCenterline');
  const validLaneDirections = new Map<'along' | 'against', MapObject[]>();
  for (const lane of lanes) {
    if (lane.laneDirection !== 'along' && lane.laneDirection !== 'against') {
      issues.push(issue('error', 'lane.direction.missing', '向きの無いレーンは安全判定に使われません。中心線と同じ向き/逆を指定してください。', lane));
      continue;
    }
    const entries = validLaneDirections.get(lane.laneDirection) ?? [];
    entries.push(lane);
    validLaneDirections.set(lane.laneDirection, entries);
  }
  for (const [direction, sameDirectionLanes] of validLaneDirections) {
    if (sameDirectionLanes.length > 1) {
      for (const lane of sameDirectionLanes) issues.push(issue('error', 'lane.direction.duplicate', `${direction === 'along' ? '中心線と同じ向き' : '中心線と逆'}のレーンは1枚だけにしてください。`, lane));
    }
  }
  if (lanes.length <= 1) {
    issues.push(issue('warning', 'lane.count', '航路レーンが揃っていません。アプリは cross 符号方式へ縮退します。'));
  }
  if (!centerline) {
    issues.push(issue(lanes.length ? 'error' : 'warning', 'centerline.missing', lanes.length ? 'レーンには規定進行方向を決める航路中心線が必要です。' : '航路中心線がありません。アプリは岸から自動導出を試みます。'));
  } else if (centerline.geometry.type === 'polyline') {
    const centerlinePoints = centerline.geometry.points;
    for (const lane of lanes) {
      if (polygonPoints(lane).some((point) => !isInsideCenterlineCoverage(point, centerlinePoints))) {
        issues.push(issue('warning', 'lane.outside.coverage', 'レーン頂点が中心線の端点より外側にあります。その区間では逆走判定が働きません。', lane));
      }
    }
  }
  for (let first = 0; first < lanes.length; first += 1) {
    for (let second = first + 1; second < lanes.length; second += 1) {
      if (polygonsOverlap(polygonPoints(lanes[first]), polygonPoints(lanes[second]))) {
        issues.push(issue('error', 'lane.overlap', '航路レーンが面で重なっています。重なった領域では規定進行方向を決められません。', lanes[first]));
        issues.push(issue('error', 'lane.overlap', '航路レーンが面で重なっています。重なった領域では規定進行方向を決められません。', lanes[second]));
      }
    }
  }
  const reverseZones = project.objects.filter((object) => object.kind === 'reverse');
  if (lanes.length >= 2) {
    for (const reverse of reverseZones) {
      const reversePoints = polygonPoints(reverse);
      const hasWideUncoveredArea = reverseZoneSamples(reversePoints).some((sample) => {
        if (lanes.some((lane) => pointInPolygon(sample, polygonPoints(lane)))) return false;
        // 意図した10m程度のレーン間隙(中央から各辺まで約5m)は警告しない。
        return lanes.every((lane) => distanceToPolygonBoundary(sample, polygonPoints(lane)) > 8);
      });
      if (hasWideUncoveredArea) {
        issues.push(issue('warning', 'lane.reverse-zone.uncovered', '逆走注意区域に、レーン間の意図した隙間を超える非判定領域があります。中州などで判定対象外にするなら reverse 区域も外してください。', reverse));
      }
    }
  }
  if (project.bakedCalibration && project.profileVersion === project.importedFrom.profileVersion) {
    issues.push(issue('error', 'calibration.bake.version', '校正差分を焼き込んだため、profileVersion を上げるまで変更適用パッケージを作れません。'));
  }
  const bridges = project.objects.filter((object) => object.kind === 'bridge');
  const bridgesById = new Map(bridges.map((bridge) => [bridge.exportId, bridge]));
  const bridgePiers = project.objects.filter((object) => object.kind === 'bridgePier');
  for (const bridge of bridges) {
    if (!bridgePiers.some((pier) => pier.bridgeId === bridge.exportId)) {
      issues.push(issue('warning', 'bridge.noPier', `橋「${bridge.name || bridge.exportId}」には橋脚がまだありません。アプリは従来の桁の警告を維持します。`, bridge));
    }
  }
  for (const pier of bridgePiers) {
    const pierPoints = polygonPoints(pier);
    if (pier.geometry.type !== 'polygon' || pierPoints.length < 3) {
      issues.push(issue('error', 'bridgePier.geometry', '橋脚は3点以上の実断面ポリゴンでなければなりません。', pier));
      continue;
    }
    if (!pier.bridgeId?.trim()) {
      issues.push(issue('error', 'bridgePier.bridgeId.missing', '橋脚には親の橋を指定してください。', pier));
      continue;
    }
    const parent = bridgesById.get(pier.bridgeId);
    if (!parent) {
      issues.push(issue('error', 'bridgePier.bridgeId.unknown', `親の橋「${pier.bridgeId}」が見つかりません。`, pier));
      continue;
    }
    const size = dimensionsMeters(pierPoints);
    if (size.long > 20 || size.short < 0.5) {
      issues.push(issue('error', 'bridgePier.size', `橋脚の外接寸法 ${size.long.toFixed(1)}m × ${size.short.toFixed(1)}m が実寸範囲外です。`, pier));
    }
    const parentPoints = pointsOf(parent.geometry);
    const center = centroid(pierPoints);
    if (parentPoints.length >= 3 && !pointInPolygon(center, parentPoints) && distanceToPolygonBoundary(center, parentPoints) > 10) {
      issues.push(issue('warning', 'bridgePier.outsideBridge', '橋脚の重心が親の橋の投影範囲（+10m）外です。親の取り違えを確認してください。', pier));
    }
    if (centerline?.geometry.type === 'polyline' && centerlineTouchesOrNearPolygon(centerline.geometry.points, pierPoints, 6)) {
      issues.push(issue('error', 'bridgePier.overlapsCenterline', '航路中心線が橋脚またはその6m以内を通っています。中心線か橋脚を修正してください。', pier));
    }
    if (pier.verificationStatus === 'aerial_only') {
      issues.push(issue('warning', 'bridgePier.aerialOnly', '航空写真のみの橋脚があります。変更適用前に現地確認結果を説明へ残してください。', pier));
    }
  }
  for (let first = 0; first < bridgePiers.length; first += 1) {
    for (let second = first + 1; second < bridgePiers.length; second += 1) {
      const a = bridgePiers[first];
      const b = bridgePiers[second];
      if (!a.bridgeId || a.bridgeId !== b.bridgeId) continue;
      if (distanceMeters(centroid(polygonPoints(a)), centroid(polygonPoints(b))) < 12) {
        issues.push(issue('warning', 'bridgePier.spanTooNarrow', '同じ橋の橋脚どうしが12m未満です。8+が通れるスパンか確認してください。', a));
      }
    }
  }
  for (const object of project.objects) {
    if (NAVIGABLE_KINDS.has(object.kind) || object.kind === 'ashoreArea') {
      if (DANGER_BASELINE_KINDS.has(object.kind) || DANGER_POLYGON_KINDS.has(object.kind)) {
        issues.push(issue('error', 'safety.category-separation', '陸上エリア・航路を危険区域に混在させてはいけません。', object));
      }
    }
  }
  return issues;
}
