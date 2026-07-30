import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'static_obstacle_model.dart';

/// 同梱された固定障害物へ端末内だけで加える位置差分。
///
/// 旧版の全体平行移動と、基準頂点ごとの東西・南北差分を分けて保持する。
/// プリセット自体は変更せず、いつでも既定位置へ戻せるよう差分だけを保存する。
class FixedObstacleCalibration {
  static const maxAbsoluteOffsetMeters = 30.0;
  static const maxVertexIndex = 999;

  final double northMeters;
  final double eastMeters;
  final Map<int, FixedObstacleVertexOffset> vertexOffsets;

  const FixedObstacleCalibration({
    this.northMeters = 0,
    this.eastMeters = 0,
    this.vertexOffsets = const {},
  });

  bool get isZero =>
      northMeters == 0 &&
      eastMeters == 0 &&
      vertexOffsets.values.every((offset) => offset.isZero);

  FixedObstacleVertexOffset vertexOffsetFor(int pointIndex) =>
      vertexOffsets[pointIndex] ?? const FixedObstacleVertexOffset();

  FixedObstacleCalibration copyWith({
    double? northMeters,
    double? eastMeters,
    Map<int, FixedObstacleVertexOffset>? vertexOffsets,
  }) {
    return FixedObstacleCalibration(
      northMeters: northMeters ?? this.northMeters,
      eastMeters: eastMeters ?? this.eastMeters,
      vertexOffsets: vertexOffsets ?? this.vertexOffsets,
    );
  }

  FixedObstacleCalibration withVertexOffset(
    int pointIndex,
    FixedObstacleVertexOffset offset,
  ) {
    if (pointIndex < 0 || pointIndex > maxVertexIndex) {
      throw ArgumentError.value(pointIndex, 'pointIndex');
    }
    final next = Map<int, FixedObstacleVertexOffset>.from(vertexOffsets);
    if (offset.isZero) {
      next.remove(pointIndex);
    } else {
      next[pointIndex] = offset;
    }
    return copyWith(vertexOffsets: next);
  }

  Map<String, dynamic> toJson() => {
        'northMeters': northMeters,
        'eastMeters': eastMeters,
        if (vertexOffsets.isNotEmpty)
          'vertexOffsets': {
            for (final entry in vertexOffsets.entries)
              '${entry.key}': entry.value.toJson(),
          },
      };

  factory FixedObstacleCalibration.fromJson(Map<String, dynamic> json) {
    final rawNorth = json['northMeters'];
    final rawEast = json['eastMeters'];
    final rawVertices = json['vertexOffsets'];
    if ((rawNorth != null && rawNorth is! num) ||
        (rawEast != null && rawEast is! num)) {
      throw const FormatException('Invalid fixed obstacle calibration type');
    }
    final north = (rawNorth as num?)?.toDouble() ?? 0;
    final east = (rawEast as num?)?.toDouble() ?? 0;
    if (!north.isFinite ||
        !east.isFinite ||
        north.abs() > maxAbsoluteOffsetMeters ||
        east.abs() > maxAbsoluteOffsetMeters) {
      throw const FormatException('Invalid fixed obstacle calibration');
    }
    final vertexOffsets = <int, FixedObstacleVertexOffset>{};
    if (rawVertices != null) {
      if (rawVertices is! Map) {
        throw const FormatException('Invalid fixed obstacle vertex offsets');
      }
      for (final entry in rawVertices.entries) {
        final pointIndex = int.tryParse(entry.key.toString());
        if (pointIndex == null ||
            pointIndex < 0 ||
            pointIndex > maxVertexIndex ||
            entry.value is! Map) {
          throw const FormatException('Invalid fixed obstacle vertex offset');
        }
        final offset = FixedObstacleVertexOffset.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
        if (!offset.isZero) vertexOffsets[pointIndex] = offset;
      }
    }
    return FixedObstacleCalibration(
      northMeters: north,
      eastMeters: east,
      vertexOffsets: vertexOffsets,
    );
  }
}

/// 固定障害物のひとつの基準頂点だけへ加える東西・南北の差分。
class FixedObstacleVertexOffset {
  final double northMeters;
  final double eastMeters;

  const FixedObstacleVertexOffset({
    this.northMeters = 0,
    this.eastMeters = 0,
  });

  bool get isZero => northMeters == 0 && eastMeters == 0;

  FixedObstacleVertexOffset copyWith({
    double? northMeters,
    double? eastMeters,
  }) =>
      FixedObstacleVertexOffset(
        northMeters: northMeters ?? this.northMeters,
        eastMeters: eastMeters ?? this.eastMeters,
      );

  Map<String, dynamic> toJson() => {
        'northMeters': northMeters,
        'eastMeters': eastMeters,
      };

  factory FixedObstacleVertexOffset.fromJson(Map<String, dynamic> json) {
    final north = json['northMeters'];
    final east = json['eastMeters'];
    if (north is! num ||
        east is! num ||
        !north.isFinite ||
        !east.isFinite ||
        north.abs() > FixedObstacleCalibration.maxAbsoluteOffsetMeters ||
        east.abs() > FixedObstacleCalibration.maxAbsoluteOffsetMeters) {
      throw const FormatException('Invalid fixed obstacle vertex offset');
    }
    return FixedObstacleVertexOffset(
      northMeters: north.toDouble(),
      eastMeters: east.toDouble(),
    );
  }
}

/// 校正画面に表示する、プリセット上の障害物単位。
///
/// 基準線から複数ポリゴンが生成される場合も[sourceId]は共通なので、
/// ひとつの障害物を選択して、その頂点だけを調整できる。
class FixedObstacleCalibrationTarget {
  final String sourceId;
  final String name;
  final StaticObstacleKind kind;
  final List<LatLng> sourcePoints;

  const FixedObstacleCalibrationTarget({
    required this.sourceId,
    required this.name,
    required this.kind,
    required this.sourcePoints,
  });
}
