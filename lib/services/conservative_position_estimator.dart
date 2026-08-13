import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../config/risk_evaluator_config.dart';
import '../config/navigator_config.dart';
import '../models/protection_budget.dart';
import '../utils/geo_math.dart';
import '../utils/heading.dart';
import 'bounded_position_set.dart';
import 'motion_state_detector.dart';

class ConservativeFix {
  final LatLng position;
  final DateTime timestamp;
  final Duration elapsed;
  final double accuracyMeters;
  final double? speedMetersPerSecond;
  final double? headingDegrees;

  const ConservativeFix({
    required this.position,
    required this.timestamp,
    required this.elapsed,
    required this.accuracyMeters,
    this.speedMetersPerSecond,
    this.headingDegrees,
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
class ConservativePositionEstimator {
  final MotionStateDetector motionStateDetector;
  ConservativeSolutionOutput? _last;
  LatLng? _lastRawPosition;
  Duration? _lastElapsed;
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

    final rawSpeed = fix.speedMetersPerSecond != null &&
            fix.speedMetersPerSecond!.isFinite &&
            fix.speedMetersPerSecond! >= 0
        ? fix.speedMetersPerSecond!
        : dt > Duration.zero
            ? displacement /
                (dt.inMicroseconds / Duration.microsecondsPerSecond)
            : 0.0;
    _speed = previous == null ? rawSpeed : _speed * .7 + rawSpeed * .3;
    final rawHeading = fix.headingDegrees;
    if (rawHeading != null &&
        rawHeading.isFinite &&
        rawHeading >= 0 &&
        rawHeading < 360) {
      _headingDegrees = _blendHeading(_headingDegrees, rawHeading, .3);
    } else if (_lastRawPosition != null && displacement >= 1.5) {
      _headingDegrees = getHeading(_lastRawPosition!, fix.position);
    }
    final motion = motionStateDetector.update(
      rawGnssSpeedMetersPerSecond: rawSpeed,
      rawDisplacementMeters: displacement,
      since: fix.elapsed,
      alongSpeedTrend: rawSpeed - (previous?.speedMetersPerSecond ?? rawSpeed),
    );
    final uncertainty =
        math.max(1.0, fix.accuracyMeters.isFinite ? fix.accuracyMeters : 5.0);
    final reliable = _speed >= stoppedSpeedThreshold &&
        _headingDegrees.isFinite &&
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
    );
    _last = output;
    _lastRawPosition = fix.position;
    _lastElapsed = fix.elapsed;
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
    );
  }

  void reset() {
    _last = null;
    _lastRawPosition = null;
    _lastElapsed = null;
    _speed = 0;
    _headingDegrees = 0;
    motionStateDetector.reset();
  }

  static double _blendHeading(double previous, double next, double weight) {
    final delta = ((next - previous + 540) % 360) - 180;
    return (previous + delta * weight + 360) % 360;
  }
}
