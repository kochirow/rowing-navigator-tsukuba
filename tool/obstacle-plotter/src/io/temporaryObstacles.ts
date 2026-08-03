import type { DocumentData } from 'firebase/firestore';
import { folderForKind } from '../model/factories';
import type { Coordinate, MapObject, ObjectKind } from '../model/types';

type TimestampLike = { toDate?: () => Date };
type GeoPointLike = { latitude?: unknown; longitude?: unknown };

export type TemporaryImportResult = {
  objects: MapObject[];
  skipped: string[];
};

function asCoordinate(value: unknown): Coordinate | null {
  const point = value as GeoPointLike | null;
  if (!point || typeof point.latitude !== 'number' || typeof point.longitude !== 'number') return null;
  if (!Number.isFinite(point.latitude) || !Number.isFinite(point.longitude)) return null;
  return { lat: point.latitude, lng: point.longitude };
}

function dateString(value: unknown): string | null {
  const date = (value as TimestampLike | null)?.toDate?.();
  return date instanceof Date && !Number.isNaN(date.getTime()) ? date.toISOString() : null;
}

function safeId(value: string): string {
  const normalized = value.toLowerCase().replace(/[^a-z0-9_]+/g, '_').replace(/^_+|_+$/g, '');
  return normalized ? `temporary_${normalized}` : 'temporary_imported';
}

function temporaryKind(value: unknown): ObjectKind {
  return value === 'curve' || value === 'reverse' || value === 'generic' || value === 'pile' ? value : 'generic';
}

/// Firestore文書を、まだ固定化していない編集候補へ変換する。
/// 読込み失敗した文書は全体を止めず、利用者に理由を返す。
export function temporaryObstacleObjects(documents: Array<DocumentData & { id: string }>): TemporaryImportResult {
  const importedAt = new Date().toISOString();
  const objects: MapObject[] = [];
  const skipped: string[] = [];
  for (const document of documents) {
    const rawPoints = document.points;
    if (!Array.isArray(rawPoints) || rawPoints.length < 3 || rawPoints.length > 200) {
      skipped.push(`${document.id}: 頂点数が3〜200ではありません`);
      continue;
    }
    const points = rawPoints.map(asCoordinate);
    if (points.some((point) => point === null)) {
      skipped.push(`${document.id}: 座標の形式が正しくありません`);
      continue;
    }
    const createdAt = dateString(document.createdAt) ?? importedAt;
    const expiresAt = dateString(document.expiresAt) ?? undefined;
    const radius = typeof document.radiusMeters === 'number' ? document.radiusMeters : null;
    objects.push({
      id: `obj_temporary_${document.id}`,
      exportId: safeId(document.id),
      name: typeof document.name === 'string' ? document.name : '臨時危険区域',
      description: [
        `Firestore臨時障害物: ${document.id}`,
        `登録: ${createdAt}`,
        ...(radius === null ? [] : [`元の円半径: ${radius}m`]),
      ].join('\n'),
      kind: temporaryKind(document.kind),
      geometry: { type: 'polygon', points: points as Coordinate[] },
      warningAudio: typeof document.warningAudio === 'string' ? document.warningAudio : null,
      parentFolderId: 'fld_imported',
      visible: true,
      locked: false,
      order: Date.now() + objects.length,
      verificationStatus: 'draft',
      origin: { kind: 'temporary', docId: document.id, createdAt, ...(expiresAt ? { expiresAt } : {}) },
      style: {},
      createdAt,
      updatedAt: importedAt,
    });
  }
  return { objects, skipped };
}

/// 昇格後はFirestore由来ではなく、同梱プロファイルへ書き出す固定候補になる。
export function promoteTemporaryObject(object: MapObject, kind: ObjectKind, exportId: string): MapObject {
  if (object.origin.kind !== 'temporary') throw new Error('臨時障害物だけを昇格できます。');
  const normalizedId = exportId.trim();
  if (!/^[a-z0-9_]{1,128}$/.test(normalizedId)) {
    throw new Error('export IDは英小文字・数字・_で1〜128文字にしてください。');
  }
  const points = object.geometry.type === 'point' ? [object.geometry.point] : object.geometry.points;
  const geometry = ['shore', 'bridge', 'island', 'driftwood', 'testZone'].includes(kind)
    ? { type: 'baseline' as const, points, closed: kind !== 'shore' }
    : { type: 'polygon' as const, points };
  return {
    ...object,
    exportId: normalizedId,
    kind,
    geometry,
    parentFolderId: folderForKind(kind),
    verificationStatus: 'field_verified',
    origin: { kind: 'drawn' },
    promotedFromTemporaryDocId: object.origin.docId,
    updatedAt: new Date().toISOString(),
  };
}
