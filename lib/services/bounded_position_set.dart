import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../config/risk_evaluator_config.dart';

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
    final double speed = speedMetersPerSecond.isFinite
        ? math.max(0, speedMetersPerSecond).toDouble()
        : 0.0;
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

/// 進行方向にだけ伸びる、線分と半径から成る到達可能領域。
///
/// 代表点は常に最後の生fixであり、このクラスは表示位置を前方へ動かさない。
/// 横方向は測位誤差と旋回で必要なぶんだけ増やす。
class CapsuleSet implements BoundedPositionSet {
  static const _earthRadiusMeters = 6371008.8;

  final LatLng start;
  final LatLng end;
  final double radiusMeters;

  const CapsuleSet({
    required this.start,
    required this.end,
    required this.radiusMeters,
  }) : assert(radiusMeters >= 0);

  @override
  LatLng get representativePoint => start;

  @override
  double get boundingRadiusMeters =>
      radiusMeters + _distanceMeters(start, end) / 2;

  @override
  BoundedPositionSet grownBy({
    required Duration elapsed,
    required double speedMetersPerSecond,
    required double headingDegrees,
    required bool headingReliable,
  }) {
    final seconds = math.max(
      0,
      elapsed.inMicroseconds / Duration.microsecondsPerSecond,
    );
    final double speed = speedMetersPerSecond.isFinite
        ? math.max(0, speedMetersPerSecond).toDouble()
        : 0.0;
    if (!headingReliable || !headingDegrees.isFinite) {
      // 方位不明時は「どの方向にも同じだけ進み得る」として円へ縮退する。
      return CircleSet(
        representativePoint: representativePoint,
        radiusMeters: radiusMeters + speed * seconds,
      );
    }
    final forward = speed * seconds * reachableForwardGrowthFactor;
    final backward =
        math.min(speed * seconds, _stoppingDistance(speed)).toDouble();
    final heading = headingDegrees * math.pi / 180;
    final east = math.sin(heading);
    final north = math.cos(heading);
    final extendedStart = _offset(start, -backward * east, -backward * north);
    final extendedEnd = _offset(end, forward * east, forward * north);
    final lateral =
        reachableMaxTurnRateRadPerSecond * seconds * speed * seconds / 2;
    return CapsuleSet(
      start: extendedStart,
      end: extendedEnd,
      radiusMeters: radiusMeters + lateral,
    );
  }

  static double _stoppingDistance(double speed) => speed * 2.0;

  @override
  BoundedPositionSet? intersect(BoundedPositionSet other) {
    if (!intersectsSet(other)) return null;
    // 交差形状を過小評価して後続判定に使わないよう、共通点を中心とした
    // 半径0の保守的な代表だけを返す。実際の判定はintersectsSetを使う。
    return CircleSet(representativePoint: representativePoint, radiusMeters: 0);
  }

  @override
  bool intersectsSet(BoundedPositionSet other) {
    if (other is CircleSet) {
      return _distancePointToSegmentMeters(
            other.representativePoint,
            start,
            end,
          ) <=
          radiusMeters + other.radiusMeters;
    }
    if (other is CapsuleSet) {
      return _distanceSegmentToSegmentMeters(
              start, end, other.start, other.end) <=
          radiusMeters + other.radiusMeters;
    }
    return other.intersectsSet(this);
  }

  @override
  bool intersectsPolygon(List<LatLng> polygon) {
    if (polygon.length < 3) return false;
    if (_pointInPolygon(start, polygon) || _pointInPolygon(end, polygon)) {
      return true;
    }
    for (var i = 0; i < polygon.length; i++) {
      if (_distanceSegmentToSegmentMeters(
            start,
            end,
            polygon[i],
            polygon[(i + 1) % polygon.length],
          ) <=
          radiusMeters) {
        return true;
      }
    }
    return false;
  }

  static LatLng _offset(LatLng from, double eastMeters, double northMeters) {
    final latitude =
        from.latitude + northMeters / _earthRadiusMeters * 180 / math.pi;
    final longitude = from.longitude +
        eastMeters /
            (_earthRadiusMeters * math.cos(from.latitude * math.pi / 180)) *
            180 /
            math.pi;
    return LatLng(latitude, longitude);
  }

  static (double, double) _local(LatLng origin, LatLng value) => (
        (value.longitude - origin.longitude) *
            math.pi /
            180 *
            _earthRadiusMeters *
            math.cos(origin.latitude * math.pi / 180),
        (value.latitude - origin.latitude) * math.pi / 180 * _earthRadiusMeters,
      );

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

  static double _distancePointToSegmentMeters(
      LatLng point, LatLng a, LatLng b) {
    final p = _local(point, point);
    final start = _local(point, a);
    final end = _local(point, b);
    return _distanceToSegment(p, start, end);
  }

  static double _distanceSegmentToSegmentMeters(
      LatLng a, LatLng b, LatLng c, LatLng d) {
    final bb = _local(a, b);
    final cc = _local(a, c);
    final dd = _local(a, d);
    if (_segmentsIntersect((0, 0), bb, cc, dd)) return 0;
    return math.min(
      math.min(
          _distanceToSegment((0, 0), cc, dd), _distanceToSegment(bb, cc, dd)),
      math.min(_distanceToSegment(cc, (0, 0), bb),
          _distanceToSegment(dd, (0, 0), bb)),
    );
  }

  static bool _segmentsIntersect((double, double) a, (double, double) b,
      (double, double) c, (double, double) d) {
    double cross((double, double) p, (double, double) q, (double, double) r) =>
        (q.$1 - p.$1) * (r.$2 - p.$2) - (q.$2 - p.$2) * (r.$1 - p.$1);
    const epsilon = 1e-9;
    bool onSegment((double, double) p, (double, double) q, (double, double) r) {
      if (cross(p, q, r).abs() > epsilon) return false;
      return r.$1 >= math.min(p.$1, q.$1) - epsilon &&
          r.$1 <= math.max(p.$1, q.$1) + epsilon &&
          r.$2 >= math.min(p.$2, q.$2) - epsilon &&
          r.$2 <= math.max(p.$2, q.$2) + epsilon;
    }

    final abC = cross(a, b, c);
    final abD = cross(a, b, d);
    final cdA = cross(c, d, a);
    final cdB = cross(c, d, b);
    final properIntersection = ((abC > epsilon && abD < -epsilon) ||
            (abC < -epsilon && abD > epsilon)) &&
        ((cdA > epsilon && cdB < -epsilon) ||
            (cdA < -epsilon && cdB > epsilon));
    if (properIntersection) return true;

    // 共線の場合は外積がすべて0になる。符号だけを見ると、互いに離れた
    // 線分まで交差扱いになるため、端点が相手の投影範囲に入るかも確認する。
    return onSegment(a, b, c) ||
        onSegment(a, b, d) ||
        onSegment(c, d, a) ||
        onSegment(c, d, b);
  }

  static double _distanceToSegment(
      (double, double) point, (double, double) a, (double, double) b) {
    final dx = b.$1 - a.$1;
    final dy = b.$2 - a.$2;
    final lengthSquared = dx * dx + dy * dy;
    final fraction = lengthSquared == 0
        ? 0.0
        : (((point.$1 - a.$1) * dx + (point.$2 - a.$2) * dy) / lengthSquared)
            .clamp(0.0, 1.0);
    final x = a.$1 + fraction * dx;
    final y = a.$2 + fraction * dy;
    return math.sqrt(
        (point.$1 - x) * (point.$1 - x) + (point.$2 - y) * (point.$2 - y));
  }

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
}
