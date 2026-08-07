import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

/// 艇が存在し得る領域。安全判定用であり、表示には代表点を使う。
///
/// Stage 1 の [CircleSet] は停止・低速専用である。航行中に等方に膨ら
/// ませると横方向へ岸へ食い込み、過剰警告を再発させるため、Stage 2 の
/// CapsuleSet が導入されるまで航行中の使用を禁じる。
abstract class BoundedPositionSet {
  LatLng get representativePoint;
  double get boundingRadiusMeters;

  BoundedPositionSet grownBy({
    required Duration elapsed,
    required double speedMetersPerSecond,
    required double headingDegrees,
    required bool headingReliable,
  });

  BoundedPositionSet? intersect(BoundedPositionSet other);
  bool intersectsPolygon(List<LatLng> polygon);
  bool intersectsSet(BoundedPositionSet other);
}

class CircleSet implements BoundedPositionSet {
  static const _earthRadiusMeters = 6371008.8;

  @override
  final LatLng representativePoint;
  final double radiusMeters;

  const CircleSet(
      {required this.representativePoint, required this.radiusMeters})
      : assert(radiusMeters >= 0);

  @override
  double get boundingRadiusMeters => radiusMeters;

  @override
  CircleSet grownBy({
    required Duration elapsed,
    required double speedMetersPerSecond,
    required double headingDegrees,
    required bool headingReliable,
  }) {
    final seconds =
        math.max(0, elapsed.inMicroseconds / Duration.microsecondsPerSecond);
    final speed =
        speedMetersPerSecond.isFinite ? math.max(0, speedMetersPerSecond) : 0.0;
    // CircleSet は低速用。方向を使わず、到達可能な量だけをMinkowski和する。
    return CircleSet(
      representativePoint: representativePoint,
      radiusMeters: radiusMeters + speed * seconds,
    );
  }

  @override
  CircleSet? intersect(BoundedPositionSet other) {
    if (other is! CircleSet) return null;
    final distance =
        _distanceMeters(representativePoint, other.representativePoint);
    if (distance > radiusMeters + other.radiusMeters) return null;
    if (distance + math.min(radiusMeters, other.radiusMeters) <=
        math.max(radiusMeters, other.radiusMeters)) {
      return radiusMeters <= other.radiusMeters ? this : other;
    }
    // 交差レンズを過大評価しないよう、両中心を結ぶ交点近くの内接円を返す。
    final overlapRadius =
        math.max(0.0, (radiusMeters + other.radiusMeters - distance) / 2);
    final fraction =
        distance == 0 ? 0.5 : (radiusMeters - overlapRadius) / distance;
    return CircleSet(
      representativePoint: _interpolate(representativePoint,
          other.representativePoint, fraction.clamp(0.0, 1.0)),
      radiusMeters: overlapRadius,
    );
  }

  @override
  bool intersectsSet(BoundedPositionSet other) {
    if (other is CircleSet) {
      return _distanceMeters(representativePoint, other.representativePoint) <=
          radiusMeters + other.radiusMeters;
    }
    return other.intersectsSet(this);
  }

  @override
  bool intersectsPolygon(List<LatLng> polygon) {
    if (polygon.length < 3) return false;
    if (_pointInPolygon(representativePoint, polygon)) return true;
    for (var i = 0; i < polygon.length; i++) {
      if (_distanceToSegmentMeters(
            representativePoint,
            polygon[i],
            polygon[(i + 1) % polygon.length],
          ) <=
          radiusMeters) {
        return true;
      }
    }
    return false;
  }

  static double _distanceMeters(LatLng a, LatLng b) {
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final dLat = lat2 - lat1;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return 2 * _earthRadiusMeters * math.asin(math.sqrt(h.clamp(0.0, 1.0)));
  }

  static LatLng _interpolate(LatLng a, LatLng b, double fraction) => LatLng(
        a.latitude + (b.latitude - a.latitude) * fraction,
        a.longitude + (b.longitude - a.longitude) * fraction,
      );

  static bool _pointInPolygon(LatLng point, List<LatLng> polygon) {
    var inside = false;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final a = polygon[i];
      final b = polygon[j];
      final crosses =
          (a.latitude > point.latitude) != (b.latitude > point.latitude) &&
              point.longitude <
                  (b.longitude - a.longitude) *
                          (point.latitude - a.latitude) /
                          (b.latitude - a.latitude) +
                      a.longitude;
      if (crosses) inside = !inside;
    }
    return inside;
  }

  static double _distanceToSegmentMeters(
      LatLng point, LatLng start, LatLng end) {
    final referenceLat = point.latitude * math.pi / 180;
    (double, double) local(LatLng value) => (
          (value.longitude - point.longitude) *
              math.pi /
              180 *
              _earthRadiusMeters *
              math.cos(referenceLat),
          (value.latitude - point.latitude) *
              math.pi /
              180 *
              _earthRadiusMeters,
        );
    final a = local(start);
    final b = local(end);
    final dx = b.$1 - a.$1;
    final dy = b.$2 - a.$2;
    final lengthSquared = dx * dx + dy * dy;
    final projection = lengthSquared == 0
        ? 0.0
        : (-(a.$1 * dx + a.$2 * dy) / lengthSquared).clamp(0.0, 1.0);
    final x = a.$1 + projection * dx;
    final y = a.$2 + projection * dy;
    return math.sqrt(x * x + y * y);
  }
}
