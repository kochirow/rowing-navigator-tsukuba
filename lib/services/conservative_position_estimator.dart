import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../config/risk_evaluator_config.dart';
import '../config/navigator_config.dart';
import '../models/protection_budget.dart';
import '../utils/geo_math.dart';
import '../utils/heading.dart';
import 'bounded_position_set.dart';
import 'gnss_motion_validity.dart';
import 'motion_state_detector.dart';

class ConservativeFix {
  final LatLng position;
  final DateTime timestamp;
  final Duration elapsed;
  final double accuracyMeters;
  final double? speedMetersPerSecond;
  final double? headingDegrees;

  /// GNSSの速度精度 [m/s]。null・0以下は「精度不明」で、値をそのまま使う。
  final double? speedAccuracyMetersPerSecond;

  /// GNSSの方位精度 [度]。null・0以下は「精度不明」で、値をそのまま使う。
  final double? headingAccuracyDegrees;

  const ConservativeFix({
    required this.position,
    required this.timestamp,
    required this.elapsed,
    required this.accuracyMeters,
    this.speedMetersPerSecond,
    this.headingDegrees,
    this.speedAccuracyMetersPerSecond,
    this.headingAccuracyDegrees,
  });
}

class ConservativeSolutionOutput {
  final LatLng representativePoint;
  final double speedMetersPerSecond;
  final double headingDegrees;
  final bool headingReliable;
  final BoundedPositionSet safetySet;
  final ProtectionBudget budget;
  final double uncertaintyMeters;
  final MotionState motionState;
  final DateTime timestamp;

  /// この測位で採用した速度・方位の出どころ。
  final GnssMotionSource speedSource;
  final GnssMotionSource headingSource;

  /// この測位1回ぶんの速度(平滑化前)。GNSSが使えればその値、使えなければ
  /// 位置の変化から求めた値。[speedSource] が held のときは平滑化後の保持値。
  final double observedSpeedMetersPerSecond;

  /// この測位のGNSS速度・方位の判定結果。
  final GnssMotionValidity? motionValidity;

  const ConservativeSolutionOutput({
    required this.representativePoint,
    required this.speedMetersPerSecond,
    required this.headingDegrees,
    required this.headingReliable,
    required this.safetySet,
    required this.budget,
    required this.uncertaintyMeters,
    required this.motionState,
    required this.timestamp,
    this.speedSource = GnssMotionSource.gnss,
    this.headingSource = GnssMotionSource.gnss,
    this.observedSpeedMetersPerSecond = 0,
    this.motionValidity,
  });
}

class ConservativeUpdateResult {
  final ConservativeSolutionOutput? output;
  final bool accepted;

  const ConservativeUpdateResult(
      {required this.output, required this.accepted});
}

/// S2の独立した保守的推定器。
///
/// 表示・共有へ返す代表点は毎回の生fixそのもの。速度と方位だけを平滑化し、
/// fixが古くなった時の到達可能性は位置を動かさず[BoundedPositionSet]へ残す。
///
/// GNSSの速度・方位は [GnssMotionValidity] で「使える」と判定したときだけ使う。
/// iOSは漕いでいる最中にも方位精度±180°・速度精度±3.75m/sの状態に入り、
/// 速度は実際の約1/4、方位は直前の値で止まる(2026-10-27・28 実機ログ)。
/// 使えない間は、直前の測位からの位置の変化で速度・方位を求め直す。
class ConservativePositionEstimator {
  final MotionStateDetector motionStateDetector;
  ConservativeSolutionOutput? _last;
  LatLng? _lastRawPosition;
  Duration? _lastElapsed;
  DateTime? _lastTimestamp;
  DateTime? _lastHeadingUpdateAt;
  double _speed = 0;
  double _headingDegrees = 0;

  ConservativePositionEstimator({MotionStateDetector? motionStateDetector})
      : motionStateDetector = motionStateDetector ?? MotionStateDetector();

  ConservativeSolutionOutput? get lastOutput => _last;

  ConservativeUpdateResult update({required ConservativeFix fix}) {
    final previous = _last;
    final previousElapsed = _lastElapsed;
    final dt =
        previousElapsed == null ? Duration.zero : fix.elapsed - previousElapsed;
    final displacement = _lastRawPosition == null
        ? 0.0
        : distanceMeters(_lastRawPosition!, fix.position);
    if (previous != null && dt > Duration.zero) {
      final allowed = conservativeMaxBoatSpeedMetersPerSecond *
              dt.inMicroseconds /
              Duration.microsecondsPerSecond +
          conservativeOutlierAllowanceMeters;
      if (displacement > allowed) {
        return ConservativeUpdateResult(output: previous, accepted: false);
      }
    }

    final validity = GnssMotionValidity.evaluate(
      speedMetersPerSecond: fix.speedMetersPerSecond,
      speedAccuracyMetersPerSecond: fix.speedAccuracyMetersPerSecond,
      headingDegrees: fix.headingDegrees,
      headingAccuracyDegrees: fix.headingAccuracyDegrees,
    );
    // 位置の変化から速度を求める間隔は、処理時刻ではなく測位時刻で測る。
    // OSが複数の測位をまとめて渡すと処理時刻の差は0に近づき、速度が跳ねる。
    final positionDt = _positionDtSeconds(fix, dt);
    final GnssMotionSource speedSource;
    final double rawSpeed;
    if (validity.speedUsable) {
      speedSource = GnssMotionSource.gnss;
      rawSpeed = fix.speedMetersPerSecond!;
    } else if (_lastRawPosition != null && positionDt > 0) {
      speedSource = GnssMotionSource.position;
      rawSpeed = displacement / positionDt;
    } else {
      speedSource = GnssMotionSource.held;
      rawSpeed = _speed;
    }
    _speed = previous == null ? rawSpeed : _speed * .7 + rawSpeed * .3;

    final lastHeadingUpdateAt = _lastHeadingUpdateAt;
    final headingWasFresh = lastHeadingUpdateAt != null &&
        fix.timestamp.difference(lastHeadingUpdateAt) <=
            gnssHeadingFreshnessWindow;
    final GnssMotionSource headingSource;
    if (validity.headingUsable) {
      headingSource = GnssMotionSource.gnss;
      _headingDegrees = _updateHeading(fix.headingDegrees!, headingWasFresh);
      _lastHeadingUpdateAt = fix.timestamp;
    } else if (_lastRawPosition != null &&
        displacement >= conservativeHeadingMinimumDisplacementMeters) {
      headingSource = GnssMotionSource.position;
      _headingDegrees = _updateHeading(
        _normalize(getHeading(_lastRawPosition!, fix.position)),
        headingWasFresh,
      );
      _lastHeadingUpdateAt = fix.timestamp;
    } else {
      headingSource = GnssMotionSource.held;
    }
    final headingUpdatedAt = _lastHeadingUpdateAt;
    final headingIsFresh = headingUpdatedAt != null &&
        fix.timestamp.difference(headingUpdatedAt) <=
            gnssHeadingFreshnessWindow;
    final motion = motionStateDetector.update(
      rawGnssSpeedMetersPerSecond: rawSpeed,
      rawDisplacementMeters: displacement,
      since: fix.elapsed,
      alongSpeedTrend: rawSpeed - (previous?.speedMetersPerSecond ?? rawSpeed),
    );
    final uncertainty =
        math.max(1.0, fix.accuracyMeters.isFinite ? fix.accuracyMeters : 5.0);
    // 方位は「使えるGNSSの値」か「位置の変化」で直近3秒以内に更新できて
    // いるときだけ信頼する。保持しているだけの方位は、停止中の回頭などで
    // 実際の向きから外れ得る。
    final reliable = _speed >= stoppedSpeedThreshold &&
        _headingDegrees.isFinite &&
        headingIsFresh &&
        motion != MotionState.stopped;
    final output = ConservativeSolutionOutput(
      representativePoint: fix.position,
      speedMetersPerSecond: _speed,
      headingDegrees: _headingDegrees,
      headingReliable: reliable,
      safetySet: CapsuleSet(
        start: fix.position,
        end: fix.position,
        radiusMeters: uncertainty,
      ),
      budget: ProtectionBudget(gnssMeasurementMeters: uncertainty),
      uncertaintyMeters: uncertainty,
      motionState: motion,
      timestamp: fix.timestamp,
      speedSource: speedSource,
      headingSource: headingSource,
      observedSpeedMetersPerSecond: rawSpeed,
      motionValidity: validity,
    );
    _last = output;
    _lastRawPosition = fix.position;
    _lastElapsed = fix.elapsed;
    _lastTimestamp = fix.timestamp;
    return ConservativeUpdateResult(output: output, accepted: true);
  }

  ConservativeSolutionOutput? predict({required Duration elapsed}) {
    final previous = _last;
    final previousElapsed = _lastElapsed;
    if (previous == null || previousElapsed == null) return null;
    final age = elapsed - previousElapsed;
    if (age <= Duration.zero) return previous;
    final motionMeters = previous.speedMetersPerSecond *
        age.inMicroseconds /
        Duration.microsecondsPerSecond;
    final budget = ProtectionBudget(
      gnssMeasurementMeters: previous.budget.gnssMeasurementMeters,
      solutionDisagreementMeters: previous.budget.solutionDisagreementMeters,
      fixAgeMotionMeters:
          math.max(previous.budget.fixAgeMotionMeters, motionMeters),
      remoteLatencyMeters: previous.budget.remoteLatencyMeters,
    );
    return ConservativeSolutionOutput(
      representativePoint: previous.representativePoint,
      speedMetersPerSecond: previous.speedMetersPerSecond,
      headingDegrees: previous.headingDegrees,
      headingReliable: previous.headingReliable,
      safetySet: previous.safetySet.grownBy(
        elapsed: age,
        speedMetersPerSecond: previous.speedMetersPerSecond,
        headingDegrees: previous.headingDegrees,
        headingReliable: previous.headingReliable,
      ),
      budget: budget,
      uncertaintyMeters: budget.totalMeters,
      motionState: previous.motionState,
      timestamp: previous.timestamp,
      speedSource: previous.speedSource,
      headingSource: previous.headingSource,
      observedSpeedMetersPerSecond: previous.observedSpeedMetersPerSecond,
      motionValidity: previous.motionValidity,
    );
  }

  void reset() {
    _last = null;
    _lastRawPosition = null;
    _lastElapsed = null;
    _lastTimestamp = null;
    _lastHeadingUpdateAt = null;
    _speed = 0;
    _headingDegrees = 0;
    motionStateDetector.reset();
  }

  /// 方位が新しければ平滑化(前回0.7・今回0.3)し、古ければ(初回・停止後の
  /// 回頭など)そのまま採る。古い方位から少しずつ寄せると、数秒間
  /// 実際と違う向きを使い続けることになる。
  double _updateHeading(double next, bool previousIsFresh) =>
      previousIsFresh ? _blendHeading(_headingDegrees, next, .3) : next;

  double _positionDtSeconds(ConservativeFix fix, Duration elapsedDt) {
    final lastTimestamp = _lastTimestamp;
    if (lastTimestamp != null) {
      final fixDt = fix.timestamp.difference(lastTimestamp);
      if (fixDt > Duration.zero &&
          fixDt <= conservativePositionSpeedMaxFixInterval) {
        return fixDt.inMicroseconds / Duration.microsecondsPerSecond;
      }
    }
    return elapsedDt > Duration.zero
        ? elapsedDt.inMicroseconds / Duration.microsecondsPerSecond
        : 0;
  }

  static double _normalize(double degrees) => (degrees % 360 + 360) % 360;

  static double _blendHeading(double previous, double next, double weight) {
    final delta = ((next - previous + 540) % 360) - 180;
    return (previous + delta * weight + 360) % 360;
  }
}
