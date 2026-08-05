export type Coordinate = { lat: number; lng: number };

export type BaselineGeometry = {
  type: 'baseline';
  points: Coordinate[];
  closed: boolean;
};
export type PolygonGeometry = { type: 'polygon'; points: Coordinate[] };
export type PolylineGeometry = { type: 'polyline'; points: Coordinate[] };
export type PointGeometry = { type: 'point'; point: Coordinate };
export type Geometry = BaselineGeometry | PolygonGeometry | PolylineGeometry | PointGeometry;

export type ObjectKind =
  | 'shore'
  | 'bridge'
  | 'bridgePier'
  | 'island'
  | 'driftwood'
  | 'pile'
  | 'testZone'
  | 'curve'
  | 'reverse'
  | 'generic'
  | 'ashoreArea'
  | 'mooringArea'
  | 'navigableWater'
  | 'lane'
  | 'practiceArea'
  | 'operationalCoverage'
  | 'channelCenterline';

export type VerificationStatus =
  | 'draft'
  | 'aerial_only'
  | 'field_verified'
  | 'field_calibrated'
  | 'needs_review';

export type ObjectOrigin =
  | { kind: 'profile' }
  | { kind: 'drawn' }
  | { kind: 'temporary'; docId: string; createdAt: string; expiresAt?: string }
  | { kind: 'calibrated'; baseExportId: string; revision: number };

export type ObjectStyle = { color?: string; opacity?: number; strokeWidth?: number };

export type Folder = {
  id: string;
  name: string;
  parentFolderId: string | null;
  expanded: boolean;
  visible: boolean;
  locked: boolean;
  order: number;
};

export type MapObject = {
  id: string;
  exportId: string;
  name: string;
  description: string;
  kind: ObjectKind;
  /// bridgePier の親となる dangerZoneBaselines の bridge exportId。
  bridgeId?: string;
  /// `lane` のときだけ、中心線の頂点順に対する規定進行方向を持つ。
  /// **安全判定（逆走）に使う内部量。** 人間の呼ぶ往路・復路とは無関係。
  laneDirection?: 'along' | 'against';
  /// `lane` のときだけ、人間の呼ぶ往路・復路を持つ。**アプリの表示専用。**
  ///
  /// アプリは地図で往路・復路をグレーの濃淡に塗り分けるためだけに読む
  /// （`lib/theme/map_layer_spec.dart` の `laneStyleFor`）。安全判定用の
  /// `ChannelLane` はこの値を一切見ない。
  ///
  /// **`laneDirection` から導いてはいけない。** 実データでも桜川河口の往路は
  /// `direction: "against"` であり、両者に対応関係は無い。id や name の
  /// 文字列から推測するのも同じ理由で禁止（名前を変えた瞬間に色が入れ替わる）。
  ///
  /// 未設定でもエクスポートは通る。アプリ側は「向きが不明な航路」として
  /// 無彩色で描き、航行も警告も止めない。
  laneLeg?: 'outbound' | 'return';
  /// `lane` が方向・経路予測の基準にする channelCenterline の exportId。
  centerlineId?: string;
  geometry: Geometry;
  warningAudio: string | null;
  parentFolderId: string | null;
  visible: boolean;
  locked: boolean;
  order: number;
  verificationStatus: VerificationStatus;
  origin: ObjectOrigin;
  /// 固定候補へ昇格する前のFirestore臨時障害物ID。変更適用手順にだけ使う。
  promotedFromTemporaryDocId?: string;
  style: ObjectStyle;
  createdAt: string;
  updatedAt: string;
};

export type ImportProvenance = {
  profileSha256: string | null;
  profileVersion: number | null;
  calibrationRevision: number | null;
  calibrationFetchedAt: string | null;
  temporaryFetchedAt: string | null;
  teamId: string | null;
};

export type Project = {
  schemaVersion: 3 | 4;
  id: string;
  name: string;
  area: string;
  profileVersion: number;
  source: string;
  notice: string;
  howToEdit: string;
  defaultObstacleProximityCautionMeters: number;
  importedFrom: ImportProvenance;
  folders: Folder[];
  objects: MapObject[];
  camera: { center: Coordinate; distance: number };
  selectedObjectId: string | null;
  createdAt: string;
  updatedAt: string;
  profileExtras: Record<string, unknown>;
  specialFieldExtras: Partial<Record<'practiceArea' | 'operationalCoveragePolygon' | 'channelCenterline', Record<string, unknown>>>;
  bakedCalibration: boolean;
};

export type ValidationLevel = 'error' | 'warning';
export type ValidationIssue = {
  level: ValidationLevel;
  code: string;
  message: string;
  objectId?: string;
};

export const DANGER_BASELINE_KINDS = new Set<ObjectKind>([
  'shore', 'bridge', 'island', 'driftwood', 'testZone',
]);
export const DANGER_POLYGON_KINDS = new Set<ObjectKind>(['bridgePier', 'pile', 'curve', 'reverse', 'generic']);
export const NAVIGABLE_KINDS = new Set<ObjectKind>(['navigableWater', 'lane']);
export const SINGLETON_KINDS = new Set<ObjectKind>([
  'practiceArea', 'operationalCoverage',
]);
