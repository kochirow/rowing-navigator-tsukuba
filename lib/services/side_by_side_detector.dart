import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../config/alert_presentation_config.dart';
import '../models/boat_model.dart';
import '../utils/geo_math.dart';
import '../utils/heading.dart';
import 'ship_domain_service.dart';

/// 並走している他艇を見つける(純Dart)。2026-11-07 利用者決定。
///
/// 次の3つが [sideBySideWindow](10秒)続いたら並走とする。
/// 1. 向きの差が [sideBySideMaxHeadingDifferenceDegrees](45°)以内
/// 2. 横の距離が [sideBySideMaxLateralMeters](30m)以内
/// 3. 10秒間の距離の変化が [sideBySideMaxDistanceChangeMeters](7m)未満
///
/// どれかが崩れた時点で並走ではなくなる。
///
/// **相手が送ってきた速さは使わない。** 2026-11-07 の実機ログでは並走中に相手の
/// 速さが実際より遅く届いた。距離は、相手の位置が届くたびに、その測位時刻と
/// 同じ時刻の自艇の位置(直近の履歴)と比べて求める。自艇の今の位置と比べると、
/// 相手の位置の古さ(最大2秒)の分だけ距離がぶれる。
///
/// 自艇・相手のどちらかの向きが信頼できない(0.5m/s未満)ときは並走としない。
/// 止まっている間は低速静音が受け持つ。
class SideBySideDetector {
  final List<_OwnSample> _own = [];
  final Map<String, _PartnerTrack> _tracks = {};

  /// いま並走している艇のID。
  Set<String> get partnerIds => {
        for (final entry in _tracks.entries)
          if (entry.value.isSideBySide) entry.key,
      };

  /// 自艇と他艇の最新の状態を渡し、並走している艇のIDを返す。
  Set<String> update({required Boat? own, required Iterable<Boat> others}) {
    if (own == null) {
      reset();
      return const {};
    }
    _recordOwn(own);
    final present = <String>{};
    for (final other in others) {
      present.add(other.boatId);
      final track = _tracks.putIfAbsent(other.boatId, _PartnerTrack.new);
      if (track.lastTimestamp == other.timestamp) continue;
      track.lastTimestamp = other.timestamp;
      _observe(track, own, other);
    }
    _tracks.removeWhere((boatId, _) => !present.contains(boatId));
    return partnerIds;
  }

  void reset() {
    _own.clear();
    _tracks.clear();
  }

  void _recordOwn(Boat own) {
    if (_own.isNotEmpty && _own.last.timestamp == own.timestamp) return;
    _own.add(_OwnSample(
      timestamp: own.timestamp,
      position: LatLng(own.lat, own.lng),
      heading: own.heading,
      headingReliable: ShipDomainService.headingIsReliable(own),
    ));
    final keepAfter = own.timestamp.subtract(sideBySideWindow * 2);
    _own.removeWhere((sample) => sample.timestamp.isBefore(keepAfter));
  }

  void _observe(_PartnerTrack track, Boat own, Boat other) {
    final ownAt = _ownAt(other.timestamp);
    final headingDiff = ownAt == null
        ? double.infinity
        : _headingDifference(ownAt.heading, other.heading);
    final otherPosition = LatLng(other.lat, other.lng);
    final ok = ownAt != null &&
        ownAt.headingReliable &&
        ShipDomainService.headingIsReliable(other) &&
        headingDiff <= sideBySideMaxHeadingDifferenceDegrees &&
        _lateralMeters(ownAt, otherPosition) <= sideBySideMaxLateralMeters;
    if (!ok) {
      track.clear();
      return;
    }
    track.add(other.timestamp, distanceMeters(ownAt.position, otherPosition));
  }

  /// [at] に最も近い自艇の位置。[sideBySideMaxTimeOffset] より離れていれば null。
  _OwnSample? _ownAt(DateTime at) {
    _OwnSample? best;
    var bestGap = sideBySideMaxTimeOffset;
    for (final sample in _own) {
      final gap = sample.timestamp.difference(at).abs();
      if (gap <= bestGap) {
        best = sample;
        bestGap = gap;
      }
    }
    return best;
  }

  static double _headingDifference(double a, double b) {
    final diff = ((a - b) % 360 + 360) % 360;
    return diff > 180 ? 360 - diff : diff;
  }

  /// 自艇の向きに直交する方向の距離 [m]。
  static double _lateralMeters(_OwnSample own, LatLng other) {
    final distance = distanceMeters(own.position, other);
    if (distance == 0) return 0;
    final bearing = getHeading(own.position, other);
    final angle = (bearing - own.heading) * math.pi / 180;
    return (distance * math.sin(angle)).abs();
  }
}

class _OwnSample {
  final DateTime timestamp;
  final LatLng position;
  final double heading;
  final bool headingReliable;

  const _OwnSample({
    required this.timestamp,
    required this.position,
    required this.heading,
    required this.headingReliable,
  });
}

class _PartnerTrack {
  DateTime? lastTimestamp;
  final List<(DateTime, double)> _distances = [];

  void add(DateTime at, double distance) {
    _distances.add((at, distance));
    // 境目のすぐ外の1点まで使うので、窓の2倍まで残す。
    final keepAfter = at.subtract(sideBySideWindow * 2);
    _distances.removeWhere((entry) => entry.$1.isBefore(keepAfter));
  }

  void clear() => _distances.clear();

  /// 条件が [sideBySideWindow] 続き、その間の距離の変化が上限未満か。
  ///
  /// 受信は不規則な時刻に届くので、窓の境目のすぐ外の1点も含めて
  /// 10秒をすき間なく覆う。条件が崩れると履歴は消えるので、残っている点は
  /// すべて条件を満たし続けた区間のものである。
  bool get isSideBySide {
    if (_distances.length < 2) return false;
    final last = _distances.last.$1;
    final boundary = last.subtract(sideBySideWindow);
    if (_distances.first.$1.isAfter(boundary)) return false;
    var start = 0;
    for (var i = 0; i < _distances.length; i++) {
      if (!_distances[i].$1.isAfter(boundary)) start = i;
    }
    var minDistance = double.infinity;
    var maxDistance = -double.infinity;
    for (final (_, distance) in _distances.skip(start)) {
      minDistance = math.min(minDistance, distance);
      maxDistance = math.max(maxDistance, distance);
    }
    return maxDistance - minDistance < sideBySideMaxDistanceChangeMeters;
  }
}
