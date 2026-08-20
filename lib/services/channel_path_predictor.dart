import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../config/risk_evaluator_config.dart';
import '../models/boat_model.dart';
import '../utils/geo_math.dart';
import '../utils/heading.dart';
import 'channel_centerline.dart';

/// 予測経路を等速直線で近似した1区間。
///
/// 連続掃引(SAT)は等速直線の掃引しか扱えないため、川なりに曲がる経路を
/// 複数の直線区間へ分けて、区間ごとに掃引する。
class PredictedMotionSegment {
  /// 区間開始時の位置。
  final LatLng origin;

  /// 区間中の進行方位 [度]。艇の領域もこの向きで作る。
  final double headingDegrees;

  final double velocityEastMetersPerSecond;
  final double velocityNorthMetersPerSecond;

  /// 予測開始からこの区間が始まるまでの時間 [秒]。
  final double startTimeSeconds;

  /// この区間の継続時間 [秒]。
  final double durationSeconds;

  /// 折れ線近似の残差と、川なりの旋回を見込んだ横方向マージン [m]。
  final double curvatureMarginMeters;

  const PredictedMotionSegment({
    required this.origin,
    required this.headingDegrees,
    required this.velocityEastMetersPerSecond,
    required this.velocityNorthMetersPerSecond,
    required this.startTimeSeconds,
    required this.durationSeconds,
    required this.curvatureMarginMeters,
  });

  double get speedMetersPerSecond => math.sqrt(
        velocityEastMetersPerSecond * velocityEastMetersPerSecond +
            velocityNorthMetersPerSecond * velocityNorthMetersPerSecond,
      );

  double get lengthMeters => speedMetersPerSecond * durationSeconds;
}

/// 艇の将来経路を、直線または航路中心線に沿った折れ線として予測する。
///
/// 中心線が無い・投影が信頼できない・停止しているなど、少しでも条件が
/// 揃わない場合は必ず従来と同じ「等速直線1区間」を返す。予測方式の
/// 変更で警告が止まることは無い。
class ChannelPathPredictor {
  const ChannelPathPredictor();

  List<PredictedMotionSegment> predict({
    required Boat boat,
    required double horizonSeconds,
    ChannelCenterline? centerline,
    int maxSegments = maxChannelPredictionSegments,
  }) {
    final speed = boat.speed.isFinite && boat.speed > 0 ? boat.speed : 0.0;
    final heading = boat.heading.isFinite ? boat.heading : 0.0;
    final safeHorizon =
        horizonSeconds.isFinite && horizonSeconds > 0 ? horizonSeconds : 0.0;
    final straight = _straightSegment(boat, speed, heading, safeHorizon);

    if (!enableChannelAwarePrediction ||
        centerline == null ||
        speed <= 0 ||
        safeHorizon <= 0 ||
        maxSegments <= 1) {
      return [straight];
    }

    final start = LatLng(boat.lat, boat.lng);
    final frame = centerline.project(start);
    if (!frame.isInsideCoverage ||
        frame.crossMeters.abs() > maxChannelProjectionOffsetMeters) {
      // 中心線の外・端点付近では投影が信頼できない。直線予測へ戻す。
      return [straight];
    }

    // 進行方向を「川に沿う成分」と「岸へ寄る成分」へ分解する。
    // 川なりに進む艇は cross 成分が小さく、岸へ向かう艇は大きい。
    final relativeRadians =
        degreesToRadians(heading - frame.tangentBearingDegrees);
    final alongSpeed = speed * math.cos(relativeRadians);
    final crossSpeed = speed * math.sin(relativeRadians);
    // 外すべきは**横断**であって**逆行ではない**。中心線の向きは岸基準線の
    // 並び順で一意に決まるので、往復コースの片道は必ず along 速度が負になる。
    // 負を捨てると航行時間の約半分で直線予測へ落ち、蛇行区間のたびに
    // カーブの外岸へ膨らんだ予測で誤警告が出る(原則4)。
    // `along = frame.alongMeters + alongSpeed * t` は負の along 速度でも
    // 中心線を正しく逆に辿り、中心線の始端を割る場合(along < 0)は
    // 終端と同じく `_appendStraightTail` が受ける。
    if (!alongSpeed.isFinite ||
        !crossSpeed.isFinite ||
        alongSpeed.abs() < speed * minimumChannelAlongSpeedRatio) {
      // ほぼ真横 = 川を横断している。中心線の助けにならないので直線でよい。
      return [straight];
    }

    final totalDistance = speed * safeHorizon;
    final segmentCount = math.min(
      maxSegments,
      math.max(
        1,
        (totalDistance / channelPredictionSegmentMinimumLengthMeters).floor(),
      ),
    );
    if (segmentCount <= 1) return [straight];

    // 曲線座標で等速に積分し、地理座標へ戻して折れ線を作る。
    final stepSeconds = safeHorizon / segmentCount;
    final points = <LatLng>[start];
    for (var index = 1; index <= segmentCount; index++) {
      final t = stepSeconds * index;
      final along = frame.alongMeters + alongSpeed * t;
      final cross = frame.crossMeters + crossSpeed * t;
      if (along < 0 || along > centerline.lengthMeters) {
        // 中心線の終端を超える予測は、以降を直線で伸ばす方が安全。
        return _appendStraightTail(
          points: points,
          boat: boat,
          stepSeconds: stepSeconds,
          consumedSegments: index - 1,
          horizonSeconds: safeHorizon,
          fallback: straight,
        );
      }
      points.add(centerline.toLatLng(alongMeters: along, crossMeters: cross));
    }

    return _segmentsFromPoints(points, stepSeconds);
  }

  /// 中心線を外れた以降を直線で伸ばす。折れ線が1区間も作れなければ直線へ。
  List<PredictedMotionSegment> _appendStraightTail({
    required List<LatLng> points,
    required Boat boat,
    required double stepSeconds,
    required int consumedSegments,
    required double horizonSeconds,
    required PredictedMotionSegment fallback,
  }) {
    if (points.length < 2) return [fallback];
    final remainingSeconds = horizonSeconds - stepSeconds * consumedSegments;
    if (remainingSeconds > 0) {
      final lastHeading = _bearing(points[points.length - 2], points.last);
      points.add(computeOffset(
        points.last,
        boat.speed * remainingSeconds,
        lastHeading,
      ));
      return _segmentsFromPoints(
        points,
        stepSeconds,
        finalSegmentSeconds: remainingSeconds,
      );
    }
    return _segmentsFromPoints(points, stepSeconds);
  }

  List<PredictedMotionSegment> _segmentsFromPoints(
    List<LatLng> points,
    double stepSeconds, {
    double? finalSegmentSeconds,
  }) {
    final segments = <PredictedMotionSegment>[];
    var startTime = 0.0;
    for (var index = 0; index < points.length - 1; index++) {
      final from = points[index];
      final to = points[index + 1];
      final isLast = index == points.length - 2;
      final duration =
          isLast ? (finalSegmentSeconds ?? stepSeconds) : stepSeconds;
      if (duration <= 0) continue;
      final segmentLength = distanceMeters(from, to);
      final heading = segmentLength <= 1e-6
          ? (index == 0 ? 0.0 : segments.last.headingDegrees)
          : _bearing(from, to);
      final headingRadians = degreesToRadians(heading);
      final segmentSpeed = segmentLength / duration;
      // 折れ線が円弧を近似する残差(弦の中央のサジッタ)。
      // 前後区間の方位差から求め、上限で頭打ちにする。
      final previousHeading =
          segments.isEmpty ? heading : segments.last.headingDegrees;
      final turnRadians =
          degreesToRadians(_shortestHeadingDelta(previousHeading, heading))
              .abs();
      final curvatureMargin = math
          .min(maxChannelCurvatureMarginMeters, segmentLength * turnRadians / 8)
          .toDouble();
      segments.add(PredictedMotionSegment(
        origin: from,
        headingDegrees: heading,
        velocityEastMetersPerSecond: segmentSpeed * math.sin(headingRadians),
        velocityNorthMetersPerSecond: segmentSpeed * math.cos(headingRadians),
        startTimeSeconds: startTime,
        durationSeconds: duration,
        curvatureMarginMeters: curvatureMargin,
      ));
      startTime += duration;
    }
    return segments;
  }

  PredictedMotionSegment _straightSegment(
    Boat boat,
    double speed,
    double heading,
    double horizonSeconds,
  ) {
    final headingRadians = degreesToRadians(heading);
    return PredictedMotionSegment(
      origin: LatLng(boat.lat, boat.lng),
      headingDegrees: heading,
      velocityEastMetersPerSecond: speed * math.sin(headingRadians),
      velocityNorthMetersPerSecond: speed * math.cos(headingRadians),
      startTimeSeconds: 0,
      durationSeconds: horizonSeconds,
      curvatureMarginMeters: 0,
    );
  }

  static double _shortestHeadingDelta(double from, double to) {
    var delta = (to - from) % 360;
    if (delta > 180) delta -= 360;
    if (delta < -180) delta += 360;
    return delta;
  }
}

/// 既存の [getHeading] は -180〜180 を返す。掃引では 0〜360 に揃える。
double _bearing(LatLng from, LatLng to) {
  final heading = getHeading(from, to);
  return heading < 0 ? heading + 360 : heading;
}
