import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../config/alert_presentation_config.dart';
import '../config/boat_config.dart';
import '../models/boat_model.dart';
import '../types/boat_type.dart';
import '../utils/geo_math.dart';
import '../utils/heading.dart';
import 'channel_centerline.dart';
import 'ship_domain_service.dart';

/// 同じ向きに漕いでいる他艇との関係(診断ログ用の名前)。
enum SameDirectionRelation {
  /// 同じ向き(並走・縦列)。その相手への他艇の警告は表示だけ。
  sameDirection,

  /// 同じ向きで、自艇が後ろから前の艇に当たりそう(追いつく側の安全網)。
  /// その相手への他艇の警告は今までどおり鳴らす。
  overtakingSafetyNet,
}

/// 同じ向きの他艇との位置関係(最新の受信時点)。
class SameDirectionStatus {
  /// 端末どうしの距離 [m]。
  final double distanceMeters;

  /// 自艇の向きに沿った距離 [m]。正なら相手が前。
  final double alongMeters;

  /// 自艇の向きに直交する方向の距離 [m](絶対値)。
  final double lateralMeters;

  /// 追いつく側の安全網に当たっているか。
  final bool safetyNet;

  /// 安全網の判定に使った値(記録・検証用)。判定まで進まなければ null。
  /// 横の距離の平均 [m]、前後の距離が縮む速さ [m/s]、艇首が届くまでの時間 [秒]。
  final double? meanLateralMeters;
  final double? closingSpeedMetersPerSecond;
  final double? secondsToContact;

  const SameDirectionStatus({
    required this.distanceMeters,
    required this.alongMeters,
    required this.lateralMeters,
    this.safetyNet = false,
    this.meanLateralMeters,
    this.closingSpeedMetersPerSecond,
    this.secondsToContact,
  });

  SameDirectionRelation get relation => safetyNet
      ? SameDirectionRelation.overtakingSafetyNet
      : SameDirectionRelation.sameDirection;
}

/// 同じ向きに漕いでいる他艇を見つける(純Dart)。2026-11-09 利用者決定。
///
/// 自艇と相手の向きがどちらも信頼でき(0.5m/s以上)、向きの差が
/// [sameDirectionMaxHeadingDifferenceDegrees](30°)以内の相手を「同じ向き」とする。
/// 並走か縦列か、距離が変わっているかは問わない。受信した最初の1点から決まる。
///
/// そのうえで、追いつく側の安全網を次のすべてで判定する。
/// - 相手が前にいる
/// - 横の距離(直近 [overtakingLateralAveragingWindow] の平均)が
///   [overtakingInPathLateralMeters] 以内
/// - 前後の距離が縮む速さ(直近 [overtakingClosingWindow] の傾き。
///   [overtakingClosingMinSpan] 以上の記録が要る)が
///   [overtakingMinClosingSpeedMetersPerSecond] 以上
/// - 艇首が前の艇の艇尾に届くまで(前後の距離 − 2艇の長さの平均)の時間が
///   [overtakingSafetyNetDeadline] 以内(測位の誤差 [overtakingPositionMarginMeters] の分
///   だけ短めに見る)
/// - まだ横に並んでいない(艇首が前の艇の艇尾を過ぎたら終える)
///
/// 前後・横は、航路中心線があれば中心線に沿って測り、無ければ自艇の向きを基準にする。
///
/// **相手が送ってきた速さは使わない。** 距離は、相手の位置が届くたびに、
/// その測位時刻と同じ時刻の自艇の位置(直近の履歴)と比べて求める。
/// 自艇の今の位置と比べると、相手の位置の古さの分だけ距離がぶれる。
///
/// 止まっている艇・向きが信頼できない艇へは今までどおり鳴る
/// (自艇が遅い間は低速静音が受け持つ)。
class SameDirectionDetector {
  SameDirectionDetector({
    this.centerlineFor,
    this.inPathLateralMeters = overtakingInPathLateralMeters,
    this.endWhenAlongside = true,
  });

  /// 艇首が前の艇の艇尾を過ぎて横に並んだ(前後の距離が当たる距離より短い)ら、
  /// 安全網を終える。後ろから当たるのは艇首が艇尾に届く瞬間なので、そこを
  /// 過ぎて当たっていなければ横を抜けている。
  final bool endWhenAlongside;

  /// 位置に対応する航路中心線(無ければ null)。あれば、前後・横を中心線に沿って
  /// 測る。自艇の向きを基準にすると、舵のぶれ(数度)とカーブで、30m先の相手の
  /// 横の距離が数mずれる。
  final ChannelCenterline? Function(LatLng position)? centerlineFor;

  /// 安全網で「相手が進路上にいる」とみなす横の距離 [m]。
  final double inPathLateralMeters;

  ChannelCenterline? Function(LatLng position)? _centerlineFor;
  final List<_OwnSample> _own = [];
  final Map<String, _PartnerTrack> _tracks = {};

  /// いま同じ向きの艇と、その位置関係。
  Map<String, SameDirectionStatus> get statuses => {
        for (final entry in _tracks.entries)
          if (entry.value.status case final status?) entry.key: status,
      };

  /// 自艇と他艇の最新の状態を渡し、同じ向きの艇を返す。
  /// [centerlineFor] を渡せば、コンストラクタの値の代わりに使う
  /// (航路中心線は航行開始後に読み込まれるため)。
  Map<String, SameDirectionStatus> update({
    required Boat? own,
    required Iterable<Boat> others,
    ChannelCenterline? Function(LatLng position)? centerlineFor,
  }) {
    _centerlineFor = centerlineFor ?? this.centerlineFor;
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
      _observe(track, own.boatType, other);
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
    final keepAfter = own.timestamp.subtract(const Duration(seconds: 5));
    _own.removeWhere((sample) => sample.timestamp.isBefore(keepAfter));
  }

  void _observe(_PartnerTrack track, BoatType ownType, Boat other) {
    final ownAt = _ownAt(other.timestamp);
    if (ownAt == null ||
        !ownAt.headingReliable ||
        !ShipDomainService.headingIsReliable(other) ||
        headingDifferenceDegrees(ownAt.heading, other.heading) >
            sameDirectionMaxHeadingDifferenceDegrees) {
      track.clear();
      return;
    }
    final otherPosition = LatLng(other.lat, other.lng);
    final geometry = _riverGeometry(ownAt, otherPosition) ??
        relativeGeometry(
          ownPosition: ownAt.position,
          ownHeading: ownAt.heading,
          otherPosition: otherPosition,
        );
    track.inPathLateralMeters = inPathLateralMeters;
    track.endWhenAlongside = endWhenAlongside;
    track.contactAlongMeters =
        (_hullLength(ownType) + _hullLength(other.boatType)) / 2;
    track.add(_PartnerSample(
      at: other.timestamp,
      distance: geometry.distanceMeters,
      along: geometry.alongMeters,
      lateral: geometry.lateralMeters,
    ));
  }

  /// 航路中心線に沿った前後・横。中心線が無い・範囲外なら null。
  ({double distanceMeters, double alongMeters, double lateralMeters})?
      _riverGeometry(_OwnSample own, LatLng otherPosition) {
    final centerline = _centerlineFor?.call(own.position);
    if (centerline == null) return null;
    final ownFrame = centerline.project(own.position);
    final otherFrame = centerline.project(otherPosition);
    if (!ownFrame.isInsideCoverage || !otherFrame.isInsideCoverage) return null;
    // 中心線の向きに進んでいれば +1、逆向きなら -1。横は進行方向の右が正。
    final travel = math.cos((own.heading - ownFrame.tangentBearingDegrees) *
                math.pi /
                180) >=
            0
        ? 1.0
        : -1.0;
    return (
      distanceMeters: distanceMeters(own.position, otherPosition),
      alongMeters: (otherFrame.alongMeters - ownFrame.alongMeters) * travel,
      lateralMeters: (otherFrame.crossMeters - ownFrame.crossMeters) * travel,
    );
  }

  /// [at] に最も近い自艇の位置。[sameDirectionMaxTimeOffset] より離れていれば null。
  _OwnSample? _ownAt(DateTime at) {
    _OwnSample? best;
    var bestGap = sameDirectionMaxTimeOffset;
    for (final sample in _own) {
      final gap = sample.timestamp.difference(at).abs();
      if (gap <= bestGap) {
        best = sample;
        bestGap = gap;
      }
    }
    return best;
  }

  static double _hullLength(BoatType type) =>
      boatConfigs.byBoatType(type).shipDomainParams.shipBodyParam.h;

  /// 2つの向きの差 [度](0〜180)。
  static double headingDifferenceDegrees(double a, double b) {
    final diff = ((a - b) % 360 + 360) % 360;
    return diff > 180 ? 360 - diff : diff;
  }

  /// 自艇の向きを基準にした相手の位置。前後は正なら前、横は正なら右。
  static ({double distanceMeters, double alongMeters, double lateralMeters})
      relativeGeometry({
    required LatLng ownPosition,
    required double ownHeading,
    required LatLng otherPosition,
  }) {
    final distance = distanceMeters(ownPosition, otherPosition);
    final angle = distance == 0
        ? 0.0
        : (getHeading(ownPosition, otherPosition) - ownHeading) * math.pi / 180;
    return (
      distanceMeters: distance,
      alongMeters: distance * math.cos(angle),
      lateralMeters: distance * math.sin(angle),
    );
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
  final double along;

  /// 横の距離 [m]。正なら右。平均するときに誤差が打ち消し合うよう符号つきで持つ。
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
  double contactAlongMeters = 0;
  double inPathLateralMeters = overtakingInPathLateralMeters;
  bool endWhenAlongside = false;
  final List<_PartnerSample> _samples = [];

  void add(_PartnerSample sample) {
    _samples.add(sample);
    final keepAfter = sample.at.subtract(overtakingClosingWindow);
    _samples.removeWhere((entry) => entry.at.isBefore(keepAfter));
  }

  void clear() => _samples.clear();

  /// 同じ向きなら位置関係を返す。条件が崩れると履歴は消えるので、
  /// 残っている点はすべて同じ向きを保っていた区間のものである。
  SameDirectionStatus? get status {
    if (_samples.isEmpty) return null;
    final last = _samples.last;
    final net = _safetyNet(last);
    return SameDirectionStatus(
      distanceMeters: last.distance,
      alongMeters: last.along,
      lateralMeters: last.lateral.abs(),
      safetyNet: net.applies,
      meanLateralMeters: net.meanLateral,
      closingSpeedMetersPerSecond: net.closing,
      secondsToContact: net.secondsToContact,
    );
  }

  ({
    bool applies,
    double? meanLateral,
    double? closing,
    double? secondsToContact
  }) _safetyNet(_PartnerSample last) {
    const none = (
      applies: false,
      meanLateral: null,
      closing: null,
      secondsToContact: null
    );
    if (last.along <= 0) return none;
    final lateralFrom = last.at.subtract(overtakingLateralAveragingWindow);
    final recent = _samples.where((s) => !s.at.isBefore(lateralFrom));
    final meanLateral =
        recent.fold<double>(0, (sum, s) => sum + s.lateral) / recent.length;
    final span = last.at.difference(_samples.first.at);
    final fit = span < overtakingClosingMinSpan ? null : _alongFit();
    final closing = fit == null ? null : -fit.slope;
    double? secondsToContact;
    var alongside = false;
    if (fit != null && closing! > 0) {
      alongside =
          fit.alongNow < contactAlongMeters - overtakingPositionMarginMeters;
      // 前後の距離は直線に当てはめた今の値で見る(1点だけの誤差に振られない)。
      // 測位の誤差の分だけ、当たるまでの距離を短めに見る。
      final gap = math.max(
        0.0,
        fit.alongNow - contactAlongMeters - overtakingPositionMarginMeters,
      );
      secondsToContact = gap / closing;
    }
    final applies = meanLateral.abs() <= inPathLateralMeters &&
        closing != null &&
        closing >= overtakingMinClosingSpeedMetersPerSecond &&
        secondsToContact != null &&
        secondsToContact * 1000 <= overtakingSafetyNetDeadline.inMilliseconds &&
        !(endWhenAlongside && alongside);
    return (
      applies: applies,
      meanLateral: meanLateral,
      closing: closing,
      secondsToContact: secondsToContact,
    );
  }

  /// 前後の距離を時間の直線に当てはめた傾き [m/s] と、最新の時刻での値 [m]
  /// (最小二乗)。
  ({double slope, double alongNow})? _alongFit() {
    final t0 = _samples.first.at;
    final n = _samples.length;
    var sumT = 0.0, sumA = 0.0, sumTT = 0.0, sumTA = 0.0;
    for (final s in _samples) {
      final t = s.at.difference(t0).inMicroseconds / 1e6;
      sumT += t;
      sumA += s.along;
      sumTT += t * t;
      sumTA += t * s.along;
    }
    final denominator = n * sumTT - sumT * sumT;
    if (denominator <= 0) return null;
    final slope = (n * sumTA - sumT * sumA) / denominator;
    final intercept = (sumA - slope * sumT) / n;
    final tNow = _samples.last.at.difference(t0).inMicroseconds / 1e6;
    return (slope: slope, alongNow: intercept + slope * tNow);
  }
}
