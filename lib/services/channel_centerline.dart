import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../config/risk_evaluator_config.dart';

/// 航路中心線上へ投影した曲線座標(Frenet座標)。
///
/// [alongMeters] は中心線に沿った距離、[crossMeters] は中心線からの
/// 横断距離(進行方位から見て右が正)。
class ChannelFrame {
  final double alongMeters;
  final double crossMeters;

  /// 投影点における中心線の接線方位 [度](北基準・時計回り)。
  final double tangentBearingDegrees;

  /// 投影が中心線の端点へ張り付いた(=水域の外)場合はfalse。
  final bool isInsideCoverage;

  const ChannelFrame({
    required this.alongMeters,
    required this.crossMeters,
    required this.tangentBearingDegrees,
    required this.isInsideCoverage,
  });
}

/// 蛇行する川の中心線を保持し、地理座標と曲線座標を相互変換する。
///
/// 直線等速の外挿は、カーブでは外岸へ突っ込む予測になり誤警告を生み、
/// 曲がった先の危険を見落とす。中心線に沿った座標系で「川沿いに進む成分」と
/// 「岸へ寄る成分」を分けて積分すると、川なりに進む艇へ誤警告を出さず、
/// 岸へ向かう艇は正しく岸に当たると予測できる。
///
/// 純Dart。Timer・通信・センサーを持たず、生成後は不変。
class ChannelCenterline {
  final LatLng origin;
  final List<double> _east;
  final List<double> _north;
  final List<double> _cumulativeMeters;

  ChannelCenterline._({
    required this.origin,
    required List<double> east,
    required List<double> north,
    required List<double> cumulativeMeters,
  })  : _east = east,
        _north = north,
        _cumulativeMeters = cumulativeMeters;

  static const double _earthRadiusMeters = 6378137.0;
  static const double _degreesToRadians = math.pi / 180;
  static const double _radiansToDegrees = 180 / math.pi;

  /// 中心線の全長 [m]。
  double get lengthMeters => _cumulativeMeters.last;

  /// 頂点数。
  int get pointCount => _east.length;

  /// 中心線の頂点を地理座標で返す。**地図描画専用。**
  ///
  /// 判定には使わない(判定は [project] / [toLatLng] の曲線座標で行う)。
  /// 一定間隔で標本化せず内部の頂点をそのまま返すのは、地図に描く線と
  /// 予測が使う線を必ず同じものにするため。標本化すると、カーブの頂点が
  /// わずかに丸まった別の線を「中央線」として見せることになる。
  List<LatLng> get vertices => List.unmodifiable(<LatLng>[
        for (var index = 0; index < _east.length; index++)
          _toLatLng(_east[index], _north[index]),
      ]);

  /// 地理座標の折れ線から中心線を作る。
  ///
  /// 頂点が2点未満、または全長が [minimumChannelCenterlineLengthMeters] 未満なら
  /// nullを返す。呼び出し側は必ず「中心線なし=従来の直線予測」へ縮退すること。
  static ChannelCenterline? fromPolyline(List<LatLng> points) {
    if (points.length < 2) return null;
    final origin = points.first;
    final originCosLatitude = math.cos(origin.latitude * _degreesToRadians);
    final east = <double>[];
    final north = <double>[];
    final cumulative = <double>[];
    for (final point in points) {
      if (!point.latitude.isFinite || !point.longitude.isFinite) return null;
      final e = (point.longitude - origin.longitude) *
          _degreesToRadians *
          _earthRadiusMeters *
          originCosLatitude;
      final n = (point.latitude - origin.latitude) *
          _degreesToRadians *
          _earthRadiusMeters;
      if (east.isNotEmpty) {
        final step = math.sqrt(
          (e - east.last) * (e - east.last) +
              (n - north.last) * (n - north.last),
        );
        // 重複頂点は距離0の区間を作り、接線が求まらないため落とす。
        if (step < 1e-3) continue;
        cumulative.add(cumulative.last + step);
      } else {
        cumulative.add(0);
      }
      east.add(e);
      north.add(n);
    }
    if (east.length < 2) return null;
    if (cumulative.last < minimumChannelCenterlineLengthMeters) return null;
    return ChannelCenterline._(
      origin: origin,
      east: east,
      north: north,
      cumulativeMeters: cumulative,
    );
  }

  /// 左右2本の岸基準線から中心線を推定する。
  ///
  /// 片方の岸を一定間隔で歩き、もう一方の岸の最近傍点との中点を採る。
  /// 川幅が想定外(極端に狭い/広い)になる区間は、基準線の向きが揃って
  /// いない可能性が高いため捨てる。妥当な標本が足りなければnullを返し、
  /// 呼び出し側は従来の直線予測へ縮退する。
  static ChannelCenterline? fromShorelines({
    required List<LatLng> firstShore,
    required List<LatLng> secondShore,
    double sampleIntervalMeters = channelCenterlineSampleIntervalMeters,
    double minimumHalfWidthMeters = minimumChannelHalfWidthMeters,
    double maximumHalfWidthMeters = maximumChannelHalfWidthMeters,
  }) {
    if (firstShore.length < 2 || secondShore.length < 2) return null;
    final guide = ChannelCenterline.fromPolyline(firstShore);
    final other = ChannelCenterline.fromPolyline(secondShore);
    if (guide == null || other == null) return null;

    final samples = <LatLng>[];
    final steps = (guide.lengthMeters / sampleIntervalMeters).floor();
    for (var index = 0; index <= steps; index++) {
      final along = math.min(index * sampleIntervalMeters, guide.lengthMeters);
      final guidePoint = guide.pointAt(along);
      final projected = other.project(guidePoint);
      // 端点へ張り付いた区間は、対岸が並走していないので使わない。
      if (!projected.isInsideCoverage) continue;
      final halfWidth = projected.crossMeters.abs() / 2;
      if (halfWidth < minimumHalfWidthMeters ||
          halfWidth > maximumHalfWidthMeters) {
        continue;
      }
      final otherPoint = other.pointAt(projected.alongMeters);
      samples.add(LatLng(
        (guidePoint.latitude + otherPoint.latitude) / 2,
        (guidePoint.longitude + otherPoint.longitude) / 2,
      ));
    }
    if (samples.length < minimumChannelCenterlineSamples) return null;
    return ChannelCenterline.fromPolyline(_smooth(samples));
  }

  /// 3点移動平均。岸基準線の頂点の粗さが中心線の接線を暴れさせるのを抑える。
  static List<LatLng> _smooth(List<LatLng> points) {
    if (points.length < 3) return points;
    final result = <LatLng>[points.first];
    for (var index = 1; index < points.length - 1; index++) {
      result.add(LatLng(
        (points[index - 1].latitude +
                points[index].latitude +
                points[index + 1].latitude) /
            3,
        (points[index - 1].longitude +
                points[index].longitude +
                points[index + 1].longitude) /
            3,
      ));
    }
    result.add(points.last);
    return result;
  }

  /// 中心線に沿った距離 [m] の地点を返す。範囲外は端点へ丸める。
  LatLng pointAt(double alongMeters) {
    final local = _localAt(alongMeters);
    return _toLatLng(local.$1, local.$2);
  }

  /// 中心線に沿った距離 [m] における接線方位 [度] を返す。
  double tangentBearingAt(double alongMeters) {
    final index = _segmentIndexFor(alongMeters);
    return _bearingOfSegment(index);
  }

  /// 曲線座標から地理座標へ戻す。
  ///
  /// [crossMeters] は接線から見て右(時計回りに90度)を正とする。
  LatLng toLatLng({
    required double alongMeters,
    required double crossMeters,
  }) {
    final local = _localAt(alongMeters);
    final index = _segmentIndexFor(alongMeters);
    final bearing = _bearingOfSegment(index) * _degreesToRadians;
    // 右手方向の単位ベクトルは、進行方向を90度時計回りに回したもの。
    final rightEast = math.cos(bearing);
    final rightNorth = -math.sin(bearing);
    return _toLatLng(
      local.$1 + rightEast * crossMeters,
      local.$2 + rightNorth * crossMeters,
    );
  }

  /// 地理座標を中心線へ投影する。
  ChannelFrame project(LatLng point) {
    final target = _toLocal(point);
    var bestDistanceSquared = double.infinity;
    var bestAlong = 0.0;
    var bestCross = 0.0;
    var bestIndex = 0;
    var bestClampedToEnd = true;

    for (var index = 0; index < _east.length - 1; index++) {
      final ax = _east[index];
      final ay = _north[index];
      final bx = _east[index + 1];
      final by = _north[index + 1];
      final dx = bx - ax;
      final dy = by - ay;
      final lengthSquared = dx * dx + dy * dy;
      if (lengthSquared <= 1e-9) continue;
      final rawT =
          ((target.$1 - ax) * dx + (target.$2 - ay) * dy) / lengthSquared;
      final t = rawT.clamp(0.0, 1.0);
      final projectedEast = ax + dx * t;
      final projectedNorth = ay + dy * t;
      final offsetEast = target.$1 - projectedEast;
      final offsetNorth = target.$2 - projectedNorth;
      final distanceSquared =
          offsetEast * offsetEast + offsetNorth * offsetNorth;
      if (distanceSquared >= bestDistanceSquared) continue;
      bestDistanceSquared = distanceSquared;
      bestIndex = index;
      bestAlong = _cumulativeMeters[index] + math.sqrt(lengthSquared) * t;
      // 進行方向の右side(時計回り90度)を正とする符号付き横断距離。
      final segmentLength = math.sqrt(lengthSquared);
      final tangentEast = dx / segmentLength;
      final tangentNorth = dy / segmentLength;
      bestCross = offsetEast * tangentNorth - offsetNorth * tangentEast;
      // 端点で丸められた=中心線の範囲外を意味する(先頭・末尾区間のみ)。
      bestClampedToEnd =
          (index == 0 && rawT < 0) || (index == _east.length - 2 && rawT > 1);
    }

    return ChannelFrame(
      alongMeters: bestAlong,
      crossMeters: bestCross,
      tangentBearingDegrees: _bearingOfSegment(bestIndex),
      isInsideCoverage: !bestClampedToEnd,
    );
  }

  int _segmentIndexFor(double alongMeters) {
    if (alongMeters <= 0) return 0;
    final maxIndex = _east.length - 2;
    if (alongMeters >= lengthMeters) return maxIndex;
    var low = 0;
    var high = maxIndex;
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      if (_cumulativeMeters[middle] <= alongMeters) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return low.clamp(0, maxIndex);
  }

  (double, double) _localAt(double alongMeters) {
    final index = _segmentIndexFor(alongMeters);
    final segmentStart = _cumulativeMeters[index];
    final segmentLength = _cumulativeMeters[index + 1] - segmentStart;
    final t = segmentLength <= 1e-9
        ? 0.0
        : ((alongMeters - segmentStart) / segmentLength).clamp(0.0, 1.0);
    return (
      _east[index] + (_east[index + 1] - _east[index]) * t,
      _north[index] + (_north[index + 1] - _north[index]) * t,
    );
  }

  double _bearingOfSegment(int index) {
    final safeIndex = index.clamp(0, _east.length - 2);
    final dx = _east[safeIndex + 1] - _east[safeIndex];
    final dy = _north[safeIndex + 1] - _north[safeIndex];
    final bearing = math.atan2(dx, dy) * _radiansToDegrees;
    return bearing < 0 ? bearing + 360 : bearing;
  }

  (double, double) _toLocal(LatLng point) {
    final originCosLatitude = math.cos(origin.latitude * _degreesToRadians);
    return (
      (point.longitude - origin.longitude) *
          _degreesToRadians *
          _earthRadiusMeters *
          originCosLatitude,
      (point.latitude - origin.latitude) *
          _degreesToRadians *
          _earthRadiusMeters,
    );
  }

  LatLng _toLatLng(double east, double north) {
    final originCosLatitude = math.cos(origin.latitude * _degreesToRadians);
    return LatLng(
      origin.latitude + north / _earthRadiusMeters * _radiansToDegrees,
      origin.longitude +
          east / (_earthRadiusMeters * originCosLatitude) * _radiansToDegrees,
    );
  }
}
