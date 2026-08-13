import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/channel_lane.dart';
import 'channel_centerline.dart';
import 'channel_lane_resolver.dart';

/// 漕手から見た左右。
///
/// **「進行方向から見た左右」ではない。** 漕手は後ろ向きに座るので、
/// 進行方向の右舷は漕手の左手側になる。地図も同じ向き
/// (`rowingMapBearing` = 進行方位 + 180度)へ回しているため、
/// **この左右はそのまま画面の左右と一致する**。
///
/// 画面と食い違う「海図の向き」を混ぜないこと。漕手が実際に経験するのは
/// 自分の体の左右だけで、そこへ翻訳を挟むと一瞥では読めなくなる。
enum RowerSide {
  /// 漕手の左手側(= 画面の左 = 進行方向の右舷)。
  left,

  /// 漕手の右手側(= 画面の右 = 進行方向の左舷)。
  right,
}

/// 断面表示に出せる情報の量。
enum ChannelCrossSectionStatus {
  /// 中央線からの距離も、左右も出せる。
  available,

  /// 距離は出せるが左右は出せない。
  ///
  /// 方位が信頼できない(低速・回頭中)ときと、レーンがどちら側にあるか
  /// 幾何から決められないとき。**距離まで消さない**(原則6: データ欠損は
  /// 安全の根拠にならない)。
  distanceOnly,

  /// 航路の情報が無い。桟橋や航路外ではこれが正常。
  unavailable,
}

/// 「いま中央線のどちら側を、どれだけ離れて走っているか」の表示用モデル。
///
/// **表示専用。** 衝突評価にも音声にも位置payloadにも渡らない。
/// レーンを外れたことを警告にはしない。岸から数mを走る・橋の下で休む・
/// 桟橋へ寄せるはいずれも正常な運用であり、そこで鳴る警告は不具合である
/// (DESIGN_PRINCIPLES 原則4)。
class ChannelCrossSection {
  final ChannelCrossSectionStatus status;

  /// 中央線からの距離 [m]。[status] が [ChannelCrossSectionStatus.unavailable]
  /// のときだけ null。
  final double? distanceFromCenterMeters;

  /// 自艇がいる側。[ChannelCrossSectionStatus.available] のときだけ入る。
  final RowerSide? boatSide;

  /// 本来入るべき側。[ChannelCrossSectionStatus.available] のときだけ入る。
  final RowerSide? expectedSide;

  const ChannelCrossSection({
    required this.status,
    this.distanceFromCenterMeters,
    this.boatSide,
    this.expectedSide,
  });

  static const ChannelCrossSection unavailable = ChannelCrossSection(
    status: ChannelCrossSectionStatus.unavailable,
  );

  /// 自艇が本来のレーン側にいるか。判定できないときは null。
  bool? get isInExpectedLane {
    final boat = boatSide;
    final expected = expectedSide;
    if (boat == null || expected == null) return null;
    return boat == expected;
  }
}

/// 自艇位置を「航路の断面」へ翻訳する。純Dart。
///
/// レーンの左右は、右側通行という規則からではなく**レーンのポリゴンそのもの**
/// から決める。同梱プロファイルでは、中心線の頂点の並び順に対してレーンが
/// どちら側に置かれているかが水域ごとに違う(霞ヶ浦の `along` レーンは
/// 中心線の左側にある)。規則から導くと、そこで左右が反転する。
///
/// レーンごとの側は形が変わらない限り不変なので、初回だけ計算して保持する。
class ChannelCrossSectionService {
  /// レーンIDごとの「中心線から見てどちら側か」。正 = 頂点の並び順に対して右。
  final Map<String, double> _laneSideCache = <String, double>{};

  /// レーンの側を決めたと認めるための最小の平均横距離 [m]。
  ///
  /// 中心線とレーンが縮退している(平均がほぼ0)ときに、丸め誤差の符号で
  /// 左右を出さないための下限。桜川のレーンは片側20m前後あるので、
  /// 1mは「決められない」だけを弾く。
  static const double _minimumMeanCrossMeters = 1.0;

  /// [position] と [headingDegrees] から断面を作る。
  ///
  /// [headingIsReliable] には `ShipDomainService.headingIsReliable` の結果を
  /// 渡す。低速時の course-over-ground は最大90度ずれるため、信頼できない
  /// ときは左右を出さない(不変条件10)。
  ChannelCrossSection describe({
    required LatLng position,
    required double? headingDegrees,
    required bool headingIsReliable,
    required ChannelLaneResolver? resolver,
  }) {
    if (resolver == null) return ChannelCrossSection.unavailable;
    final lane = resolver.resolveLane(position);
    final centerline = resolver.centerlineFor(position);
    if (lane == null || centerline == null) {
      return ChannelCrossSection.unavailable;
    }

    final frame = centerline.project(position);
    final crossMeters = frame.crossMeters;
    if (!crossMeters.isFinite) return ChannelCrossSection.unavailable;
    final distance = crossMeters.abs();

    if (headingDegrees == null ||
        !headingDegrees.isFinite ||
        !headingIsReliable) {
      return ChannelCrossSection(
        status: ChannelCrossSectionStatus.distanceOnly,
        distanceFromCenterMeters: distance,
      );
    }

    final laneSide = _laneSideSign(lane, centerline);
    if (laneSide == null) {
      return ChannelCrossSection(
        status: ChannelCrossSectionStatus.distanceOnly,
        distanceFromCenterMeters: distance,
      );
    }

    // 中心線の頂点の並び順に沿って進んでいるか。
    final headingOffset =
        (headingDegrees - frame.tangentBearingDegrees) * math.pi / 180;
    final travelsAlong = math.cos(headingOffset) >= 0;

    // いま入っているレーンが、自分の進行方向のレーンか。
    final laneMatchesTravel =
        (lane.direction == LaneDirection.along) == travelsAlong;
    // 入るべきレーンの側(中心線の頂点の並び順に対する左右)。
    final expectedSideAlongTangent = laneMatchesTravel ? laneSide : -laneSide;

    return ChannelCrossSection(
      status: ChannelCrossSectionStatus.available,
      distanceFromCenterMeters: distance,
      boatSide: _toRowerSide(crossMeters, travelsAlong: travelsAlong),
      expectedSide:
          _toRowerSide(expectedSideAlongTangent, travelsAlong: travelsAlong),
    );
  }

  /// 中心線の接線基準の横距離を、漕手から見た左右へ翻訳する。
  ///
  /// 接線基準で右 → 並び順に沿って進むなら右舷 → 漕手の左手側。
  /// 逆走りなら左右が入れ替わる。
  static RowerSide _toRowerSide(
    double crossAlongTangent, {
    required bool travelsAlong,
  }) {
    final starboard =
        travelsAlong ? crossAlongTangent >= 0 : crossAlongTangent < 0;
    return starboard ? RowerSide.left : RowerSide.right;
  }

  /// レーンが中心線のどちら側にあるか。正 = 並び順に対して右。
  ///
  /// 頂点の横距離の平均を使う。レーンの片側の辺は中心線に重なっている
  /// (横距離ほぼ0)ので、中央値や重心では符号が立たない。平均なら外側の辺が
  /// そのまま符号になる。
  double? _laneSideSign(ChannelLane lane, ChannelCenterline centerline) {
    final cached = _laneSideCache[lane.id];
    if (cached != null) return cached;
    if (lane.points.isEmpty) return null;
    var sum = 0.0;
    var count = 0;
    for (final point in lane.points) {
      final cross = centerline.project(point).crossMeters;
      if (!cross.isFinite) continue;
      sum += cross;
      count++;
    }
    if (count == 0) return null;
    final mean = sum / count;
    if (mean.abs() < _minimumMeanCrossMeters) return null;
    final sign = mean.isNegative ? -1.0 : 1.0;
    _laneSideCache[lane.id] = sign;
    return sign;
  }
}
