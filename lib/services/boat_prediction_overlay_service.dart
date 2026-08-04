import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/boat_model.dart';
import '../utils/geo_math.dart';
import 'channel_centerline.dart';
import 'channel_path_predictor.dart';

/// 地図に出す「この先どこへ行くか」の表示形状(純Dart)。
///
/// **表示専用。** ここで作る折れ線は安全判定にも他艇へも一切渡らない。
/// 判定は従来どおり [ChannelPathPredictor] の区間を連続掃引(SAT)へ渡す
/// 経路で行い、この描画が失敗しても警告は一切変わらない(不変条件4)。
class BoatPredictionOverlay {
  /// 予測経路の折れ線。先頭が艇の現在位置、末尾が予測地平。
  ///
  /// 中心線があれば川なりに曲がり、無ければ2点の直線へ縮退する
  /// ([ChannelPathPredictor] の縮退規則をそのまま受け継ぐ)。
  final List<LatLng> pathPoints;

  /// 停止距離の位置に立てる横棒(2点)。
  ///
  /// 速度0で経路が作れないとき、または停止距離が予測地平より先にある
  /// ときは null。「棒が見えない = そこまでの範囲では止まれる保証が無い」
  /// ではなく「棒を置ける経路が無い」を意味するので、棒の欠如を
  /// 安全の根拠にしないこと(原則6)。
  final List<LatLng>? stoppingTick;

  const BoatPredictionOverlay({
    required this.pathPoints,
    required this.stoppingTick,
  });
}

/// 艇の予測経路と停止距離の印を作る。
///
/// 以前は「船体領域の六角形 + 掃引外形の凸包 + 停止距離の閉じた輪」の
/// 3枚を艇のまわりへ入れ子に描いていた。**入れ子の同心図形は、大きさの
/// 順序を暗記しないと読めない。** 漕手は後ろ向きで、地図は回転していて、
/// 視線を送れるのは1秒未満である(`map_layer_spec.dart` の帯を廃止した
/// 記録と同じ論拠)。
///
/// 舶用の衝突回避表示(ECDIS / ARPA)は、自船を面ではなく
/// **「船首方位線 + 速度ベクトル」**で描き、面は実際に危険と判定された
/// 場所にだけ使う。ここでも同じ作法を採り、
///   - 平常時は**線1本と横棒1つ**(長さで読める)
///   - 掃引の面は**警告が出ているあいだだけ**、その警告の色で
/// とする。`map_layer_spec.dart` の「塗り = 実在する危険 / 線 = 予測」
/// という規則とも一致する。
///
/// [stoppingDistanceMeters] は `CollisionRiskEvaluatorService` が返す値を
/// そのまま渡す。ここでは判定に使わず、経路上の位置を決めるだけ。
/// [tickHalfWidthMeters] は排他領域の半幅を渡す(横棒が排他領域の幅を
/// 表すので、艇種で棒の長さが変わる)。
BoatPredictionOverlay? buildBoatPredictionOverlay({
  required Boat boat,
  required double horizonSeconds,
  required double stoppingDistanceMeters,
  required double tickHalfWidthMeters,
  ChannelCenterline? centerline,
  ChannelPathPredictor predictor = const ChannelPathPredictor(),
  double minimumPathLengthMeters = 1.0,
}) {
  if (!boat.lat.isFinite ||
      !boat.lng.isFinite ||
      boat.lat.abs() > 90 ||
      boat.lng.abs() > 180) {
    return null;
  }
  final segments = predictor.predict(
    boat: boat,
    horizonSeconds: horizonSeconds,
    centerline: centerline,
  );
  if (segments.isEmpty) return null;

  // 折れ線を組む。区間は「開始位置 + 方位 + 長さ」なので、各区間の終点を
  // 順に足していく。区間長が0(停止中)なら点が重なるだけで害は無い。
  final points = <LatLng>[segments.first.origin];
  final segmentLengths = <double>[];
  for (final segment in segments) {
    final length = segment.lengthMeters;
    if (!length.isFinite || length <= 0) {
      segmentLengths.add(0);
      continue;
    }
    points.add(computeOffset(
      points.last,
      length,
      segment.headingDegrees,
    ));
    segmentLengths.add(length);
  }

  final totalLength = segmentLengths.fold<double>(0, (sum, v) => sum + v);
  // 停止中は進行方向を示すベクトルが存在しない。無理に短い線を出すと
  // 「ごく手前で止まる」という別の意味に読めるので、何も描かない。
  if (points.length < 2 || totalLength < minimumPathLengthMeters) return null;

  return BoatPredictionOverlay(
    pathPoints: points,
    stoppingTick: _stoppingTick(
      points: points,
      segments: segments,
      segmentLengths: segmentLengths,
      totalLength: totalLength,
      stoppingDistanceMeters: stoppingDistanceMeters,
      halfWidthMeters: tickHalfWidthMeters,
    ),
  );
}

/// 経路上を [stoppingDistanceMeters] だけ進んだ点に、進行方向と直交する
/// 横棒を立てる。停止距離が予測地平より先なら null(棒を地平へ張り付けて
/// 「ここで止まれる」と誤読させない)。
List<LatLng>? _stoppingTick({
  required List<LatLng> points,
  required List<PredictedMotionSegment> segments,
  required List<double> segmentLengths,
  required double totalLength,
  required double stoppingDistanceMeters,
  required double halfWidthMeters,
}) {
  if (!stoppingDistanceMeters.isFinite || stoppingDistanceMeters <= 0) {
    return null;
  }
  if (!halfWidthMeters.isFinite || halfWidthMeters <= 0) return null;
  if (stoppingDistanceMeters > totalLength) return null;

  var remaining = stoppingDistanceMeters;
  var pointIndex = 0;
  for (var index = 0; index < segmentLengths.length; index++) {
    final length = segmentLengths[index];
    if (length <= 0) continue;
    if (remaining <= length || index == segmentLengths.length - 1) {
      final heading = segments[index].headingDegrees;
      final center = computeOffset(
        points[pointIndex],
        remaining.clamp(0.0, length),
        heading,
      );
      return [
        computeOffset(center, halfWidthMeters, heading - 90),
        computeOffset(center, halfWidthMeters, heading + 90),
      ];
    }
    remaining -= length;
    pointIndex++;
  }
  return null;
}
