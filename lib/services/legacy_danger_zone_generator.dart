import 'dart:math';

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/danger_zone_settings.dart';
import '../models/static_obstacle_model.dart';

class DangerZoneBaseline {
  final String id;
  final String name;
  final DangerZoneKind kind;
  final List<LatLng> points;
  final String? warningAudioAsset;

  const DangerZoneBaseline({
    required this.id,
    required this.name,
    required this.kind,
    required this.points,
    this.warningAudioAsset,
  });

  factory DangerZoneBaseline.fromJson(Map<String, dynamic> json) {
    return DangerZoneBaseline(
      id: json['id'] as String,
      name: json['name'] as String,
      kind: DangerZoneKind.fromJson(json['kind'] as String),
      points: (json['points'] as List<dynamic>)
          .map((point) => LatLng(
                (point['lat'] as num).toDouble(),
                (point['lng'] as num).toDouble(),
              ))
          .toList(growable: false),
      warningAudioAsset: json['warningAudio'] as String?,
    );
  }
}

/// 旧iOSアプリと同じ規則で、基準線の各辺を長方形の危険区域へ変換する。
///
/// 頂点順を基準に進行方位-90度をwaterSide、+90度をlandSideとする。
/// 距離は旧UI値ではなく、基準線からの実際の片側距離[m]を受け取る。
class LegacyDangerZoneGenerator {
  static const _earthRadiusMeters = 6371000.0;

  List<StaticObstacle> generate({
    required List<DangerZoneBaseline> baselines,
    required DangerZoneSettings settings,

    /// kind別の既定値を上書きする指定 [m]。nullなら既定値を使う。
    double? proximityCautionDistanceMeters,
    Set<String> disabledWarningSourceIds = const {},
  }) {
    final obstacles = <StaticObstacle>[];
    for (final baseline in baselines) {
      if (baseline.points.length < 2) continue;
      final offsets = settings[baseline.kind];
      for (var i = 0; i < baseline.points.length - 1; i++) {
        final start = baseline.points[i];
        final end = baseline.points[i + 1];
        if (start == end) continue;
        obstacles.add(StaticObstacle(
          id: 'default_${baseline.id}_$i',
          sourceId: baseline.id,
          name: '${baseline.name} ${i + 1}',
          points: createDangerRectangle(
            start: start,
            end: end,
            waterSideMeters: offsets.waterSideMeters,
            landSideMeters: offsets.landSideMeters,
          ),
          isDefault: true,
          isWarningEnabled: !disabledWarningSourceIds.contains(baseline.id),
          proximityCautionDistanceMeters: proximityCautionDistanceMeters,
          kind: _obstacleKindFor(baseline.kind),
          warningAudioAsset: baseline.warningAudioAsset,
        ));
      }
    }
    return obstacles;
  }

  StaticObstacleKind _obstacleKindFor(DangerZoneKind kind) {
    switch (kind) {
      case DangerZoneKind.shore:
        return StaticObstacleKind.shore;
      case DangerZoneKind.bridge:
        return StaticObstacleKind.bridge;
      case DangerZoneKind.island:
        return StaticObstacleKind.island;
      case DangerZoneKind.driftwood:
        return StaticObstacleKind.driftwood;
      case DangerZoneKind.testZone:
        return StaticObstacleKind.testZone;
    }
  }

  List<LatLng> createDangerRectangle({
    required LatLng start,
    required LatLng end,
    required double waterSideMeters,
    required double landSideMeters,
  }) {
    final bearing = _bearing(start, end);
    final waterBearing = bearing - 90.0;
    final landBearing = bearing + 90.0;
    return [
      _destination(start, waterBearing, waterSideMeters),
      _destination(end, waterBearing, waterSideMeters),
      _destination(end, landBearing, landSideMeters),
      _destination(start, landBearing, landSideMeters),
    ];
  }

  double _bearing(LatLng from, LatLng to) {
    final lat1 = _radians(from.latitude);
    final lon1 = _radians(from.longitude);
    final lat2 = _radians(to.latitude);
    final lon2 = _radians(to.longitude);
    final y = sin(lon2 - lon1) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(lon2 - lon1);
    return _degrees(atan2(y, x));
  }

  LatLng _destination(LatLng from, double bearing, double distanceMeters) {
    final angularDistance = distanceMeters / _earthRadiusMeters;
    final bearingRad = _radians(bearing);
    final lat = _radians(from.latitude);
    final lng = _radians(from.longitude);
    final newLat = asin(sin(lat) * cos(angularDistance) +
        cos(lat) * sin(angularDistance) * cos(bearingRad));
    final newLng = lng +
        atan2(
          sin(bearingRad) * sin(angularDistance) * cos(lat),
          cos(angularDistance) - sin(lat) * sin(newLat),
        );
    return LatLng(_degrees(newLat), _degrees(newLng));
  }

  double _radians(double degrees) => degrees * pi / 180.0;
  double _degrees(double radians) => radians * 180.0 / pi;
}
