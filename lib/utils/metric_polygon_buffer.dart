import 'dart:math';

import 'package:google_maps_flutter/google_maps_flutter.dart';

/// 緯度経度ポリゴンを局所メートル座標へ移し、各辺から指定距離だけ
/// 外側へ平行移動する。
///
/// 現在は同梱の固定流木のような凸ポリゴンを対象にする。鋭角の頂点は
/// 過大なmiterを避けてbevelへ切り替えるが、各辺からの距離は維持する。
class MetricPolygonBuffer {
  static const _earthRadiusMeters = 6378137.0;
  static const _closingToleranceDegrees = 1e-9;

  const MetricPolygonBuffer();

  List<LatLng> expand(
    List<LatLng> rawPoints,
    double distanceMeters,
  ) {
    if (!distanceMeters.isFinite || distanceMeters < 0) {
      throw ArgumentError.value(
        distanceMeters,
        'distanceMeters',
        'must be finite and non-negative',
      );
    }
    final points = _withoutDuplicateClosingPoint(rawPoints);
    if (points.length < 3 || distanceMeters == 0) {
      return List<LatLng>.unmodifiable(points);
    }
    final origin = LatLng(
      points.map((point) => point.latitude).reduce((a, b) => a + b) /
          points.length,
      points.map((point) => point.longitude).reduce((a, b) => a + b) /
          points.length,
    );
    final local =
        points.map((point) => _toLocal(origin, point)).toList(growable: false);
    final signedArea = _signedArea(local);
    if (signedArea.abs() < 1e-6) {
      throw const FormatException('Cannot buffer a degenerate polygon');
    }
    final counterClockwise = signedArea > 0;
    final edges = <_Edge>[];
    for (var index = 0; index < local.length; index++) {
      final start = local[index];
      final end = local[(index + 1) % local.length];
      final dx = end.x - start.x;
      final dy = end.y - start.y;
      final length = sqrt(dx * dx + dy * dy);
      if (length < 1e-6) {
        throw const FormatException('Cannot buffer duplicate polygon points');
      }
      final normal = counterClockwise
          ? _Point(dy / length, -dx / length)
          : _Point(-dy / length, dx / length);
      edges.add(_Edge(direction: _Point(dx, dy), normal: normal));
    }

    final expanded = <_Point>[];
    final maxMiterLength = max(0.1, distanceMeters * 4);
    for (var index = 0; index < local.length; index++) {
      final vertex = local[index];
      final previous = edges[(index - 1 + edges.length) % edges.length];
      final current = edges[index];
      final previousOffset = vertex + previous.normal * distanceMeters;
      final currentOffset = vertex + current.normal * distanceMeters;
      final intersection = _lineIntersection(
        previousOffset,
        previous.direction,
        currentOffset,
        current.direction,
      );
      if (intersection == null ||
          (intersection - vertex).length > maxMiterLength) {
        // 鋭角で遠方へ突出しないよう、2点のbevelでつなぐ。
        expanded
          ..add(previousOffset)
          ..add(currentOffset);
      } else {
        expanded.add(intersection);
      }
    }
    return expanded
        .map((point) => _fromLocal(origin, point))
        .toList(growable: false);
  }

  List<LatLng> _withoutDuplicateClosingPoint(List<LatLng> points) {
    if (points.length > 3 &&
        (points.first.latitude - points.last.latitude).abs() <
            _closingToleranceDegrees &&
        (points.first.longitude - points.last.longitude).abs() <
            _closingToleranceDegrees) {
      return points.sublist(0, points.length - 1);
    }
    return List<LatLng>.from(points);
  }

  double _signedArea(List<_Point> points) {
    var sum = 0.0;
    for (var index = 0; index < points.length; index++) {
      final current = points[index];
      final next = points[(index + 1) % points.length];
      sum += current.x * next.y - next.x * current.y;
    }
    return sum / 2;
  }

  _Point? _lineIntersection(
    _Point first,
    _Point firstDirection,
    _Point second,
    _Point secondDirection,
  ) {
    final denominator = _cross(firstDirection, secondDirection);
    if (denominator.abs() < 1e-9) return null;
    final t = _cross(second - first, secondDirection) / denominator;
    return first + firstDirection * t;
  }

  double _cross(_Point a, _Point b) => a.x * b.y - a.y * b.x;

  _Point _toLocal(LatLng origin, LatLng point) {
    final meanLatitude = (origin.latitude + point.latitude) / 2 * pi / 180;
    return _Point(
      (point.longitude - origin.longitude) *
          pi /
          180 *
          cos(meanLatitude) *
          _earthRadiusMeters,
      (point.latitude - origin.latitude) * pi / 180 * _earthRadiusMeters,
    );
  }

  LatLng _fromLocal(LatLng origin, _Point point) {
    final latitude = origin.latitude + point.y / _earthRadiusMeters * 180 / pi;
    final longitude = origin.longitude +
        point.x /
            (_earthRadiusMeters * cos(origin.latitude * pi / 180)) *
            180 /
            pi;
    return LatLng(latitude, longitude);
  }
}

class _Edge {
  final _Point direction;
  final _Point normal;

  const _Edge({
    required this.direction,
    required this.normal,
  });
}

class _Point {
  final double x;
  final double y;

  const _Point(this.x, this.y);

  _Point operator +(_Point other) => _Point(x + other.x, y + other.y);
  _Point operator -(_Point other) => _Point(x - other.x, y - other.y);
  _Point operator *(double scale) => _Point(x * scale, y * scale);
  double get length => sqrt(x * x + y * y);
}
