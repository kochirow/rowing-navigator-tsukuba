enum DangerZoneKind {
  shore,
  bridge,
  island,
  driftwood,
  testZone;

  static DangerZoneKind fromJson(String value) {
    return DangerZoneKind.values.firstWhere(
      (kind) => kind.name == value,
      orElse: () => throw FormatException('Unknown danger-zone kind: $value'),
    );
  }
}

class DangerZoneOffsets {
  final double waterSideMeters;
  final double landSideMeters;

  const DangerZoneOffsets({
    required this.waterSideMeters,
    required this.landSideMeters,
  });

  DangerZoneOffsets copyWith({
    double? waterSideMeters,
    double? landSideMeters,
  }) {
    return DangerZoneOffsets(
      waterSideMeters: waterSideMeters ?? this.waterSideMeters,
      landSideMeters: landSideMeters ?? this.landSideMeters,
    );
  }
}

/// 通常の固定危険区域を基準線から外側へ広げるデフォルト距離 [m]。
/// カーブ／逆走区域は完成ポリゴンとして別管理するため、この値の対象外。
const defaultDangerZoneExpansionMeters = 5.0;

/// 岸の基準線から水面側へ広げる既定距離 [m]。
///
/// 桜川の狭所は川幅35m・片側レーン12.5mで、岸から数mを走るのは
/// 正常な運用である(DESIGN_PRINCIPLES 1.1, 1.4)。15mへ広げると
/// 片側航路をほぼ潰して常時警告になるため、5mにする。
const defaultShoreWaterSideExpansionMeters = 5.0;

/// 岸の基準線から陸側へ広げる既定距離 [m]。
/// 陸地側の欠損を覆い、陸上判定・地図表示に必要な余裕なので、
/// 水面側とは独立に15mを保つ。
const defaultShoreLandSideExpansionMeters = 15.0;

/// 橋の基準線から内外へ広げる既定距離 [m]。
/// 毎回くぐって通過する橋で15mを取ると警告が形骸化するため、5mにする。
const defaultBridgeExpansionMeters = 5.0;

/// アプリ内で調整できる固定危険区域の片側拡張距離 [m]。
const minDangerZoneOffsetMeters = 0.0;
const maxDangerZoneOffsetMeters = 30.0;
const dangerZoneOffsetStepMeters = 0.5;

class DangerZoneSettings {
  final Map<DangerZoneKind, DangerZoneOffsets> _offsets;

  DangerZoneSettings(Map<DangerZoneKind, DangerZoneOffsets> offsets)
      : _offsets = Map.unmodifiable(offsets);

  /// 現行UIでは混乱を避けるため、実際の片側距離をそのまま保持・表示する。
  /// 既定は岸が水面側5m/陸側15m、橋は内外5m、それ以外が片側5m。
  factory DangerZoneSettings.defaults() => DangerZoneSettings({
        DangerZoneKind.shore: const DangerZoneOffsets(
          waterSideMeters: defaultShoreWaterSideExpansionMeters,
          landSideMeters: defaultShoreLandSideExpansionMeters,
        ),
        DangerZoneKind.bridge: const DangerZoneOffsets(
          waterSideMeters: defaultBridgeExpansionMeters,
          landSideMeters: defaultBridgeExpansionMeters,
        ),
        DangerZoneKind.island: const DangerZoneOffsets(
          waterSideMeters: defaultDangerZoneExpansionMeters,
          landSideMeters: defaultDangerZoneExpansionMeters,
        ),
        DangerZoneKind.driftwood: const DangerZoneOffsets(
          waterSideMeters: defaultDangerZoneExpansionMeters,
          landSideMeters: defaultDangerZoneExpansionMeters,
        ),
        // テスト区域もカーブ／逆走ではないため、通常区域と同じ片側5mとする。
        DangerZoneKind.testZone: const DangerZoneOffsets(
          waterSideMeters: defaultDangerZoneExpansionMeters,
          landSideMeters: defaultDangerZoneExpansionMeters,
        ),
      });

  DangerZoneOffsets operator [](DangerZoneKind kind) => _offsets[kind]!;

  DangerZoneSettings withOffsets(
    DangerZoneKind kind,
    DangerZoneOffsets offsets,
  ) {
    return DangerZoneSettings({..._offsets, kind: offsets});
  }
}
