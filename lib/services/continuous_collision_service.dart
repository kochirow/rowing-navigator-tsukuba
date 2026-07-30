import 'dart:math';

import 'package:google_maps_flutter/google_maps_flutter.dart';

/// A collision result over the complete closed interval `[0, horizon]`.
///
/// Unlike a point-in-time prediction, this keeps the first entry even when the
/// moving domain has already left the obstacle again at the prediction end.
class ContinuousIntersection {
  final bool intersects;
  final bool currentOverlap;
  final double? firstEntryTimeSeconds;
  final double? firstExitTimeSeconds;
  final double? firstEntryDistanceMeters;
  final double minimumSeparationMeters;
  final double confidence;
  final List<String> reasonCodes;

  const ContinuousIntersection({
    required this.intersects,
    required this.currentOverlap,
    required this.firstEntryTimeSeconds,
    required this.firstExitTimeSeconds,
    this.firstEntryDistanceMeters,
    required this.minimumSeparationMeters,
    this.confidence = 1.0,
    this.reasonCodes = const [],
  });

  const ContinuousIntersection.none({
    double minimumSeparationMeters = double.infinity,
    List<String> reasonCodes = const [],
  }) : this(
          intersects: false,
          currentOverlap: false,
          firstEntryTimeSeconds: null,
          firstExitTimeSeconds: null,
          minimumSeparationMeters: minimumSeparationMeters,
          reasonCodes: reasonCodes,
        );

  ContinuousIntersection copyWith({
    bool? currentOverlap,
    double? firstEntryDistanceMeters,
    double? confidence,
    List<String>? reasonCodes,
  }) {
    return ContinuousIntersection(
      intersects: intersects,
      currentOverlap: currentOverlap ?? this.currentOverlap,
      firstEntryTimeSeconds: firstEntryTimeSeconds,
      firstExitTimeSeconds: firstExitTimeSeconds,
      firstEntryDistanceMeters:
          firstEntryDistanceMeters ?? this.firstEntryDistanceMeters,
      minimumSeparationMeters: minimumSeparationMeters,
      confidence: confidence ?? this.confidence,
      reasonCodes: reasonCodes ?? this.reasonCodes,
    );
  }
}

/// Continuous collision detection for a polygon translated at constant speed.
///
/// All calculations use a local east/north plane in metres. A static concave
/// polygon is ear-clipped into triangles; each triangle is then evaluated with
/// continuous SAT. Ship domains are convex, so no time sampling is involved.
class ContinuousCollisionService {
  static const _earthRadiusMeters = 6378137.0;
  static const _epsilon = 1e-9;

  /// Sweeps [movingPolygon] against an arbitrary simple [staticPolygon].
  ContinuousIntersection sweepAgainstStatic({
    required List<LatLng> movingPolygon,
    required List<LatLng> staticPolygon,
    required LatLng origin,
    required double velocityEastMetersPerSecond,
    required double velocityNorthMetersPerSecond,
    required double horizonSeconds,
    double inflateMeters = 0,
  }) {
    _validateInputs(
        movingPolygon, staticPolygon, horizonSeconds, inflateMeters);
    final moving = _convexHull(_toLocal(movingPolygon, origin));
    final obstacle = _cleanPolygon(_toLocal(staticPolygon, origin));
    final triangles = _triangulate(obstacle);

    var result = const ContinuousIntersection.none();
    for (final triangle in triangles) {
      final part = _sweepConvex(
        moving: moving,
        stationary: triangle,
        velocity: _Point(
          velocityEastMetersPerSecond,
          velocityNorthMetersPerSecond,
        ),
        horizonSeconds: horizonSeconds,
        inflateMeters: inflateMeters,
      );
      result = combine(result, part);
    }
    return result;
  }

  /// Sweeps [movingPolygon] using [relativeVelocity] against [otherPolygon].
  ///
  /// If the absolute velocities are `vMoving` and `vOther`, pass
  /// `relativeVelocity = vMoving - vOther`. This preserves synchronized time:
  /// geographically crossing tracks do not collide when arrival times differ.
  ContinuousIntersection sweepRelative({
    required List<LatLng> movingPolygon,
    required List<LatLng> otherPolygon,
    required LatLng origin,
    required double relativeVelocityEastMetersPerSecond,
    required double relativeVelocityNorthMetersPerSecond,
    required double horizonSeconds,
    double inflateMeters = 0,
  }) {
    _validateInputs(movingPolygon, otherPolygon, horizonSeconds, inflateMeters);
    return _sweepConvex(
      moving: _convexHull(_toLocal(movingPolygon, origin)),
      stationary: _convexHull(_toLocal(otherPolygon, origin)),
      velocity: _Point(
        relativeVelocityEastMetersPerSecond,
        relativeVelocityNorthMetersPerSecond,
      ),
      horizonSeconds: horizonSeconds,
      inflateMeters: inflateMeters,
    );
  }

  /// Combines alternative collision configurations without losing an earlier
  /// entry (for example own-exclusive/other-body and the reverse pairing).
  ContinuousIntersection combine(
      ContinuousIntersection a, ContinuousIntersection b) {
    if (!a.intersects && !b.intersects) {
      return ContinuousIntersection.none(
        minimumSeparationMeters:
            min(a.minimumSeparationMeters, b.minimumSeparationMeters),
        reasonCodes: {...a.reasonCodes, ...b.reasonCodes}.toList(),
      );
    }
    if (!a.intersects) return b;
    if (!b.intersects) return a;
    return ContinuousIntersection(
      intersects: true,
      currentOverlap: a.currentOverlap || b.currentOverlap,
      firstEntryTimeSeconds: min(
        a.firstEntryTimeSeconds!,
        b.firstEntryTimeSeconds!,
      ),
      firstExitTimeSeconds: max(
        a.firstExitTimeSeconds!,
        b.firstExitTimeSeconds!,
      ),
      firstEntryDistanceMeters: _minNullable(
        a.firstEntryDistanceMeters,
        b.firstEntryDistanceMeters,
      ),
      minimumSeparationMeters:
          min(a.minimumSeparationMeters, b.minimumSeparationMeters),
      confidence: min(a.confidence, b.confidence),
      reasonCodes: {...a.reasonCodes, ...b.reasonCodes}.toList(),
    );
  }

  ContinuousIntersection _sweepConvex({
    required List<_Point> moving,
    required List<_Point> stationary,
    required _Point velocity,
    required double horizonSeconds,
    required double inflateMeters,
  }) {
    if (moving.length < 3 || stationary.length < 3) {
      throw const FormatException('Collision polygons need at least 3 points');
    }

    var enter = double.negativeInfinity;
    var exit = double.infinity;
    var overlapsAtZero = true;
    final axes = <_Point>[
      ..._edgeNormals(moving),
      ..._edgeNormals(stationary),
    ];

    for (final axis in axes) {
      final movingRange = _project(moving, axis);
      final staticRange = _project(stationary, axis);
      final staticMin = staticRange.min - inflateMeters;
      final staticMax = staticRange.max + inflateMeters;
      final speed = velocity.dot(axis);

      final overlapsNow = movingRange.max >= staticMin - _epsilon &&
          movingRange.min <= staticMax + _epsilon;
      overlapsAtZero = overlapsAtZero && overlapsNow;

      if (speed.abs() <= _epsilon) {
        if (!overlapsNow) {
          return ContinuousIntersection.none(
            minimumSeparationMeters: _sweptMinimumSeparation(
              moving,
              stationary,
              velocity,
              horizonSeconds,
              inflateMeters,
            ),
          );
        }
        continue;
      }

      final t1 = (staticMin - movingRange.max) / speed;
      final t2 = (staticMax - movingRange.min) / speed;
      final axisEnter = min(t1, t2);
      final axisExit = max(t1, t2);
      enter = max(enter, axisEnter);
      exit = min(exit, axisExit);
      if (enter > exit + _epsilon) {
        return ContinuousIntersection.none(
          minimumSeparationMeters: _sweptMinimumSeparation(
            moving,
            stationary,
            velocity,
            horizonSeconds,
            inflateMeters,
          ),
        );
      }
    }

    final clippedEnter = max(0.0, enter);
    final clippedExit = min(horizonSeconds, exit);
    if (clippedEnter > clippedExit + _epsilon ||
        clippedExit < -_epsilon ||
        clippedEnter > horizonSeconds + _epsilon) {
      return ContinuousIntersection.none(
        minimumSeparationMeters: _sweptMinimumSeparation(
          moving,
          stationary,
          velocity,
          horizonSeconds,
          inflateMeters,
        ),
      );
    }

    return ContinuousIntersection(
      intersects: true,
      currentOverlap: overlapsAtZero,
      firstEntryTimeSeconds: overlapsAtZero ? 0 : clippedEnter,
      firstExitTimeSeconds: max(0.0, clippedExit),
      minimumSeparationMeters: 0,
      reasonCodes: const ['continuous_domain_entry'],
    );
  }

  double _sweptMinimumSeparation(
    List<_Point> moving,
    List<_Point> stationary,
    _Point velocity,
    double horizonSeconds,
    double inflateMeters,
  ) {
    final endOffset = velocity * horizonSeconds;
    final sweptHull = _convexHull([
      ...moving,
      ...moving.map((point) => point + endOffset),
    ]);
    return max(0, _polygonDistance(sweptHull, stationary) - inflateMeters);
  }

  double _polygonDistance(List<_Point> a, List<_Point> b) {
    var best = double.infinity;
    for (var i = 0; i < a.length; i++) {
      final a1 = a[i];
      final a2 = a[(i + 1) % a.length];
      for (var j = 0; j < b.length; j++) {
        final b1 = b[j];
        final b2 = b[(j + 1) % b.length];
        if (_segmentsIntersect(a1, a2, b1, b2)) return 0;
        best = min(best, _pointSegmentDistance(a1, b1, b2));
        best = min(best, _pointSegmentDistance(b1, a1, a2));
      }
    }
    if (_pointInConvex(a.first, b) || _pointInConvex(b.first, a)) return 0;
    return best;
  }

  List<_Point> _edgeNormals(List<_Point> polygon) {
    final result = <_Point>[];
    for (var i = 0; i < polygon.length; i++) {
      final edge = polygon[(i + 1) % polygon.length] - polygon[i];
      final length = edge.length;
      if (length <= _epsilon) continue;
      result.add(_Point(-edge.y / length, edge.x / length));
    }
    return result;
  }

  _Range _project(List<_Point> polygon, _Point axis) {
    var minValue = double.infinity;
    var maxValue = double.negativeInfinity;
    for (final point in polygon) {
      final value = point.dot(axis);
      minValue = min(minValue, value);
      maxValue = max(maxValue, value);
    }
    return _Range(minValue, maxValue);
  }

  List<_Point> _toLocal(List<LatLng> points, LatLng origin) {
    final originLatRadians = origin.latitude * pi / 180;
    return points.map((point) {
      final north =
          (point.latitude - origin.latitude) * pi / 180 * _earthRadiusMeters;
      final east = (point.longitude - origin.longitude) *
          pi /
          180 *
          _earthRadiusMeters *
          cos(originLatRadians);
      return _Point(east, north);
    }).toList(growable: false);
  }

  List<List<_Point>> _triangulate(List<_Point> input) {
    if (input.length < 3) {
      throw const FormatException('Obstacle needs at least 3 distinct points');
    }
    var polygon = List<_Point>.from(input);
    if (_signedArea(polygon) < 0) polygon = polygon.reversed.toList();
    final result = <List<_Point>>[];
    var safety = polygon.length * polygon.length;

    while (polygon.length > 3 && safety-- > 0) {
      var earFound = false;
      for (var i = 0; i < polygon.length; i++) {
        final previous = polygon[(i - 1 + polygon.length) % polygon.length];
        final current = polygon[i];
        final next = polygon[(i + 1) % polygon.length];
        if ((current - previous).cross(next - current) <= _epsilon) continue;
        var containsPoint = false;
        for (var j = 0; j < polygon.length; j++) {
          if (j == i ||
              j == (i - 1 + polygon.length) % polygon.length ||
              j == (i + 1) % polygon.length) {
            continue;
          }
          if (_pointInTriangle(polygon[j], previous, current, next)) {
            containsPoint = true;
            break;
          }
        }
        if (containsPoint) continue;
        result.add([previous, current, next]);
        polygon.removeAt(i);
        earFound = true;
        break;
      }
      if (!earFound) {
        throw const FormatException(
            'Obstacle polygon is self-intersecting or degenerate');
      }
    }
    if (polygon.length != 3) {
      throw const FormatException('Obstacle triangulation did not converge');
    }
    result.add(List<_Point>.from(polygon));
    return result;
  }

  List<_Point> _cleanPolygon(List<_Point> input) {
    final result = <_Point>[];
    for (final point in input) {
      if (result.isEmpty || (point - result.last).length > _epsilon) {
        result.add(point);
      }
    }
    if (result.length > 1 && (result.first - result.last).length <= _epsilon) {
      result.removeLast();
    }
    return result;
  }

  List<_Point> _convexHull(List<_Point> input) {
    final points = _cleanPolygon(input).toList()
      ..sort((a, b) => a.x == b.x ? a.y.compareTo(b.y) : a.x.compareTo(b.x));
    if (points.length < 3) return points;
    final lower = <_Point>[];
    for (final point in points) {
      while (lower.length >= 2 &&
          (lower.last - lower[lower.length - 2]).cross(point - lower.last) <=
              _epsilon) {
        lower.removeLast();
      }
      lower.add(point);
    }
    final upper = <_Point>[];
    for (final point in points.reversed) {
      while (upper.length >= 2 &&
          (upper.last - upper[upper.length - 2]).cross(point - upper.last) <=
              _epsilon) {
        upper.removeLast();
      }
      upper.add(point);
    }
    return [
      ...lower.sublist(0, lower.length - 1),
      ...upper.sublist(0, upper.length - 1)
    ];
  }

  double _signedArea(List<_Point> polygon) {
    var sum = 0.0;
    for (var i = 0; i < polygon.length; i++) {
      sum += polygon[i].cross(polygon[(i + 1) % polygon.length]);
    }
    return sum / 2;
  }

  bool _pointInTriangle(_Point p, _Point a, _Point b, _Point c) {
    final c1 = (b - a).cross(p - a);
    final c2 = (c - b).cross(p - b);
    final c3 = (a - c).cross(p - c);
    return c1 >= -_epsilon && c2 >= -_epsilon && c3 >= -_epsilon;
  }

  bool _pointInConvex(_Point point, List<_Point> polygon) {
    var sign = 0;
    for (var i = 0; i < polygon.length; i++) {
      final cross = (polygon[(i + 1) % polygon.length] - polygon[i])
          .cross(point - polygon[i]);
      if (cross.abs() <= _epsilon) continue;
      final currentSign = cross > 0 ? 1 : -1;
      if (sign != 0 && sign != currentSign) return false;
      sign = currentSign;
    }
    return true;
  }

  bool _segmentsIntersect(_Point a, _Point b, _Point c, _Point d) {
    final abC = (b - a).cross(c - a);
    final abD = (b - a).cross(d - a);
    final cdA = (d - c).cross(a - c);
    final cdB = (d - c).cross(b - c);
    return abC * abD <= _epsilon && cdA * cdB <= _epsilon;
  }

  double _pointSegmentDistance(_Point p, _Point a, _Point b) {
    final edge = b - a;
    final lengthSquared = edge.dot(edge);
    if (lengthSquared <= _epsilon) return (p - a).length;
    final t = ((p - a).dot(edge) / lengthSquared).clamp(0.0, 1.0);
    return (p - (a + edge * t)).length;
  }

  void _validateInputs(List<LatLng> first, List<LatLng> second,
      double horizonSeconds, double inflateMeters) {
    if (first.length < 3 || second.length < 3) {
      throw const FormatException('Collision polygons need at least 3 points');
    }
    if (!horizonSeconds.isFinite || horizonSeconds < 0) {
      throw ArgumentError.value(horizonSeconds, 'horizonSeconds');
    }
    if (!inflateMeters.isFinite || inflateMeters < 0) {
      throw ArgumentError.value(inflateMeters, 'inflateMeters');
    }
  }

  double? _minNullable(double? a, double? b) {
    if (a == null) return b;
    if (b == null) return a;
    return min(a, b);
  }
}

class _Point {
  final double x;
  final double y;

  const _Point(this.x, this.y);

  _Point operator +(_Point other) => _Point(x + other.x, y + other.y);
  _Point operator -(_Point other) => _Point(x - other.x, y - other.y);
  _Point operator *(double scalar) => _Point(x * scalar, y * scalar);
  double dot(_Point other) => x * other.x + y * other.y;
  double cross(_Point other) => x * other.y - y * other.x;
  double get length => sqrt(x * x + y * y);
}

class _Range {
  final double min;
  final double max;

  const _Range(this.min, this.max);
}
