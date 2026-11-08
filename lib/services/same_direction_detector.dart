import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../config/alert_presentation_config.dart';
import '../models/boat_model.dart';
import '../utils/geo_math.dart';
import '../utils/heading.dart';
import 'ship_domain_service.dart';

/// 同じ向きに漕いでいる他艇との関係。
enum SameDirectionRelation {
  /// 並走している(距離がほとんど変わらない)。
  sideBySide,

  /// 自艇が後ろから相手に追いついている(相手が前・距離が縮んでいる)。
  overtaking,

  /// 自艇が相手に追いつかれている(相手が後ろ・距離が縮んでいる)。
  overtaken,
}

/// 同じ向きの他艇との関係と、そのときの横の距離。
class SameDirectionStatus {
  final SameDirectionRelation relation;

  /// 自艇の向きに直交する方向の距離 [m](最新の受信時点)。
  final double lateralMeters;

  const SameDirectionStatus({
    required this.relation,
    required this.lateralMeters,
  });
}

/// 同じ向きに漕いでいる他艇との関係(並走・追いつく・追いつかれる)を見る(純Dart)。
/// 2026-11-07・08 利用者決定。
///
/// 次の2つが [sideBySideWindow](10秒)続いた相手だけを対象にする。
/// - 向きの差が [sideBySideMaxHeadingDifferenceDegrees](45°)以内
/// - 横の距離が [sideBySideMaxLateralMeters](30m)以内
///
/// その10秒の距離の変化で関係を決める。
/// - 変化(最大−最小)が [sideBySideMaxDistanceChangeMeters](7m)未満 → 並走
/// - 窓の始まりから一番近づいた点までに同じ量以上縮んでいる → 追いつく・追いつかれる。
///   前後は**縮み始めた時点**(窓の始まり)の位置で決める。横を抜けて前後が入れ替わり、
///   距離が増え始めても、最接近から10秒は関係を保つ(抜けている最中に鳴らさない)。
/// - それ以外(離れていく) → 関係なし
///
/// 条件のどれかが崩れた時点で関係なしに戻る。
///
/// **相手が送ってきた速さは使わない。** 2026-11-07 の実機ログでは並走中に相手の
/// 速さが実際より遅く届いた。距離は、相手の位置が届くたびに、その測位時刻と
/// 同じ時刻の自艇の位置(直近の履歴)と比べて求める。自艇の今の位置と比べると、
/// 相手の位置の古さ(最大2秒)の分だけ距離がぶれる。
///
/// 自艇・相手のどちらかの向きが信頼できない(0.5m/s未満)ときは対象にしない。
/// 止まっている艇へは今までどおり鳴る(自艇が止まっている間は低速静音が受け持つ)。
class SameDirectionDetector {
  final List<_OwnSample> _own = [];
  final Map<String, _PartnerTrack> _tracks = {};

  /// いま同じ向きの関係にある艇と、その関係。
  Map<String, SameDirectionStatus> get statuses => {
        for (final entry in _tracks.entries)
          if (entry.value.status case final status?) entry.key: status,
      };

  /// 自艇と他艇の最新の状態を渡し、同じ向きの関係にある艇を返す。
  Map<String, SameDirectionStatus> update({
    required Boat? own,
    required Iterable<Boat> others,
  }) {
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
      _observe(track, other);
    }
    _tracks.removeWhere((boatId, _) => !present.contains(boatId));
    return statuses;
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

  void _observe(_PartnerTrack track, Boat other) {
    final ownAt = _ownAt(other.timestamp);
    if (ownAt == null ||
        !ownAt.headingReliable ||
        !ShipDomainService.headingIsReliable(other) ||
        _headingDifference(ownAt.heading, other.heading) >
            sideBySideMaxHeadingDifferenceDegrees) {
      track.clear();
      return;
    }
    final otherPosition = LatLng(other.lat, other.lng);
    final distance = distanceMeters(ownAt.position, otherPosition);
    final angle = distance == 0
        ? 0.0
        : (getHeading(ownAt.position, otherPosition) - ownAt.heading) *
            math.pi /
            180;
    final lateral = (distance * math.sin(angle)).abs();
    if (lateral > sideBySideMaxLateralMeters) {
      track.clear();
      return;
    }
    track.add(_PartnerSample(
      at: other.timestamp,
      distance: distance,
      along: distance * math.cos(angle),
      lateral: lateral,
    ));
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

class _PartnerSample {
  final DateTime at;
  final double distance;

  /// 自艇の向きに沿った距離 [m]。正なら相手が前。
  final double along;
  final double lateral;

  const _PartnerSample({
    required this.at,
    required this.distance,
    required this.along,
    required this.lateral,
  });
}

class _PartnerTrack {
  DateTime? lastTimestamp;
  final List<_PartnerSample> _samples = [];

  void add(_PartnerSample sample) {
    _samples.add(sample);
    // 境目のすぐ外の1点まで使うので、窓の2倍まで残す。
    final keepAfter = sample.at.subtract(sideBySideWindow * 2);
    _samples.removeWhere((entry) => entry.at.isBefore(keepAfter));
  }

  void clear() => _samples.clear();

  /// 条件が [sideBySideWindow] 続いていれば、その間の距離の変化で関係を返す。
  ///
  /// 受信は不規則な時刻に届くので、窓の境目のすぐ外の1点も含めて
  /// 10秒をすき間なく覆う。条件が崩れると履歴は消えるので、残っている点は
  /// すべて条件を満たし続けた区間のものである。
  SameDirectionStatus? get status {
    if (_samples.length < 2) return null;
    final last = _samples.last;
    final boundary = last.at.subtract(sideBySideWindow);
    if (_samples.first.at.isAfter(boundary)) return null;
    var start = 0;
    for (var i = 0; i < _samples.length; i++) {
      if (!_samples[i].at.isAfter(boundary)) start = i;
    }
    final window = _samples.sublist(start);
    var minDistance = double.infinity;
    var maxDistance = -double.infinity;
    for (final sample in window) {
      minDistance = math.min(minDistance, sample.distance);
      maxDistance = math.max(maxDistance, sample.distance);
    }
    final SameDirectionRelation relation;
    if (maxDistance - minDistance < sideBySideMaxDistanceChangeMeters) {
      relation = SameDirectionRelation.sideBySide;
    } else if (window.first.distance - minDistance >=
        sideBySideMaxDistanceChangeMeters) {
      // 窓の始まりから一番近づいた点まで縮んでいれば、追いつく・追いつかれるの途中。
      // 横を抜けて距離が増え始めても、接近が窓に残る間(最接近から10秒)は続ける。
      relation = window.first.along > 0
          ? SameDirectionRelation.overtaking
          : SameDirectionRelation.overtaken;
    } else {
      return null;
    }
    return SameDirectionStatus(
      relation: relation,
      lateralMeters: last.lateral,
    );
  }
}
