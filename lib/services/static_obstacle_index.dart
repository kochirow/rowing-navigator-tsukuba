import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/static_obstacle_model.dart';

/// 固定危険区域の粗い空間索引。
///
/// 桜川の同梱プロファイルは岸の基準線を辺ごとの長方形へ展開するため、
/// release でも 310 枚前後になる。1Hzの評価でそれを毎回全走査すると、
/// 実際に関係するのは周囲の数枚だけなのに CPU を使い続けることになる。
///
/// 生成時に各区域の外接矩形を固定サイズのグリッドへ登録し、問い合わせでは
/// 半径が触れるセルの区域だけを返す。索引が答えを変えることは無く、
/// 返す集合は必ず「本当に必要な区域」を含む上位集合(保守的)。
class StaticObstacleIndex {
  static const double _earthRadiusMeters = 6378137.0;
  static const double _degreesToRadians = math.pi / 180;

  /// グリッドの1辺 [m]。桜川の岸リボン(20〜30m)と同程度にすると、
  /// 1セルあたりの区域数が数枚に収まる。
  final double cellSizeMeters;

  final List<StaticObstacle> obstacles;
  final LatLng _origin;
  final double _originCosLatitude;
  final Map<int, List<int>> _cells = {};
  final List<_Bounds> _bounds = [];

  StaticObstacleIndex(
    List<StaticObstacle> source, {
    this.cellSizeMeters = 40,
  })  : obstacles = List.unmodifiable(source),
        _origin = _originOf(source),
        _originCosLatitude =
            math.cos(_originOf(source).latitude * _degreesToRadians) {
    for (var index = 0; index < obstacles.length; index++) {
      final points = obstacles[index].points;
      if (points.isEmpty) {
        _bounds.add(const _Bounds.empty());
        continue;
      }
      var minEast = double.infinity;
      var maxEast = double.negativeInfinity;
      var minNorth = double.infinity;
      var maxNorth = double.negativeInfinity;
      for (final point in points) {
        final local = _toLocal(point);
        minEast = math.min(minEast, local.$1);
        maxEast = math.max(maxEast, local.$1);
        minNorth = math.min(minNorth, local.$2);
        maxNorth = math.max(maxNorth, local.$2);
      }
      if (!minEast.isFinite || !minNorth.isFinite) {
        _bounds.add(const _Bounds.empty());
        continue;
      }
      _bounds.add(_Bounds(minEast, minNorth, maxEast, maxNorth));
      final fromX = (minEast / cellSizeMeters).floor();
      final toX = (maxEast / cellSizeMeters).floor();
      final fromY = (minNorth / cellSizeMeters).floor();
      final toY = (maxNorth / cellSizeMeters).floor();
      for (var x = fromX; x <= toX; x++) {
        for (var y = fromY; y <= toY; y++) {
          _cells.putIfAbsent(_key(x, y), () => <int>[]).add(index);
        }
      }
    }
  }

  int get length => obstacles.length;

  /// [center] から [radiusMeters] 以内に外接矩形が触れる区域を返す。
  ///
  /// 返る集合は保守的な上位集合。正確な距離判定は呼び出し側で行う。
  List<StaticObstacle> query(LatLng center, double radiusMeters) {
    if (!radiusMeters.isFinite || radiusMeters < 0) return obstacles;
    if (obstacles.isEmpty) return const [];
    final local = _toLocal(center);
    final fromX = ((local.$1 - radiusMeters) / cellSizeMeters).floor();
    final toX = ((local.$1 + radiusMeters) / cellSizeMeters).floor();
    final fromY = ((local.$2 - radiusMeters) / cellSizeMeters).floor();
    final toY = ((local.$2 + radiusMeters) / cellSizeMeters).floor();
    // 半径が異常に大きい場合は、索引を使う意味が無いので全件返す。
    if ((toX - fromX + 1) * (toY - fromY + 1) > 4096) return obstacles;

    final seen = <int>{};
    final result = <StaticObstacle>[];
    for (var x = fromX; x <= toX; x++) {
      for (var y = fromY; y <= toY; y++) {
        final bucket = _cells[_key(x, y)];
        if (bucket == null) continue;
        for (final index in bucket) {
          if (!seen.add(index)) continue;
          if (!_bounds[index].touches(local.$1, local.$2, radiusMeters)) {
            continue;
          }
          result.add(obstacles[index]);
        }
      }
    }
    return result;
  }

  static LatLng _originOf(List<StaticObstacle> source) {
    for (final obstacle in source) {
      for (final point in obstacle.points) {
        if (point.latitude.isFinite && point.longitude.isFinite) return point;
      }
    }
    return const LatLng(0, 0);
  }

  (double, double) _toLocal(LatLng point) => (
        (point.longitude - _origin.longitude) *
            _degreesToRadians *
            _earthRadiusMeters *
            _originCosLatitude,
        (point.latitude - _origin.latitude) *
            _degreesToRadians *
            _earthRadiusMeters,
      );

  static int _key(int x, int y) => (x << 20) ^ (y & 0xFFFFF);
}

class _Bounds {
  final double minEast;
  final double minNorth;
  final double maxEast;
  final double maxNorth;

  const _Bounds(this.minEast, this.minNorth, this.maxEast, this.maxNorth);

  const _Bounds.empty()
      : minEast = double.infinity,
        minNorth = double.infinity,
        maxEast = double.negativeInfinity,
        maxNorth = double.negativeInfinity;

  bool touches(double east, double north, double radius) {
    if (!minEast.isFinite) return false;
    final dx = east < minEast
        ? minEast - east
        : east > maxEast
            ? east - maxEast
            : 0.0;
    final dy = north < minNorth
        ? minNorth - north
        : north > maxNorth
            ? north - maxNorth
            : 0.0;
    return dx * dx + dy * dy <= radius * radius;
  }
}
