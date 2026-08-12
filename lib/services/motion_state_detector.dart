import '../config/navigator_config.dart';

enum MotionState { moving, decelerating, stopped, restarting }

/// 推定器の内部速度を参照しない停止状態の検出器。
///
/// GNSS速度・生位置変位・速度低下を短時間に蓄積する。ここで得た状態は
/// 保守的推定器の集合形状だけに渡し、他艇警告の静音根拠には使わない。
class MotionStateDetector {
  final Duration stoppedConfirmDuration;
  final Duration restartConfirmDuration;
  MotionState _state = MotionState.moving;
  Duration? _lowMotionSince;
  Duration? _movingSince;

  MotionStateDetector({
    this.stoppedConfirmDuration = const Duration(seconds: 3),
    this.restartConfirmDuration = const Duration(seconds: 1),
  });

  MotionState get state => _state;

  MotionState update({
    required double rawGnssSpeedMetersPerSecond,
    required double rawDisplacementMeters,
    required Duration since,
    double? alongSpeedTrend,
  }) {
    final lowSpeed = rawGnssSpeedMetersPerSecond.isFinite &&
        rawGnssSpeedMetersPerSecond < stoppedSpeedThreshold;
    final lowDisplacement =
        rawDisplacementMeters.isFinite && rawDisplacementMeters < 1.5;
    final slowing = alongSpeedTrend == null || alongSpeedTrend <= 0;
    final lowMotion = lowSpeed && lowDisplacement && slowing;
    if (lowMotion) {
      _lowMotionSince ??= since;
      _movingSince = null;
      if (since - _lowMotionSince! >= stoppedConfirmDuration) {
        _state = MotionState.stopped;
      } else if (_state == MotionState.moving) {
        _state = MotionState.decelerating;
      }
      return _state;
    }

    _lowMotionSince = null;
    final moving = rawGnssSpeedMetersPerSecond.isFinite &&
        rawGnssSpeedMetersPerSecond >= stoppedSpeedThreshold;
    if (moving) {
      _movingSince ??= since;
      if (_state == MotionState.stopped &&
          since - _movingSince! < restartConfirmDuration) {
        _state = MotionState.restarting;
      } else {
        _state = MotionState.moving;
      }
    } else {
      _movingSince = null;
      _state = MotionState.decelerating;
    }
    return _state;
  }

  void reset() {
    _state = MotionState.moving;
    _lowMotionSince = null;
    _movingSince = null;
  }
}
