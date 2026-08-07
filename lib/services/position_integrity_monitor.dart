import 'dart:math' as math;

enum PositionIntegrityState {
  trusted,
  suspect,
  ambiguous,
  fallback,
  reacquiring
}

class PositionIntegrityObservation {
  final Duration elapsed;
  final double separationMeters;
  final double protectionS1Meters;
  final double protectionConsensusMeters;
  final double motionAllowanceMeters;
  final bool rawAndConservativeAgree;
  final bool fixIsFresh;

  const PositionIntegrityObservation({
    required this.elapsed,
    required this.separationMeters,
    required this.protectionS1Meters,
    required this.protectionConsensusMeters,
    required this.motionAllowanceMeters,
    required this.rawAndConservativeAgree,
    required this.fixIsFresh,
  });

  double get separationScore =>
      separationMeters /
      math.max(
          1.0,
          protectionS1Meters +
              protectionConsensusMeters +
              motionAllowanceMeters);
}

/// S1/S0/S2の分離を、S1自身と独立に状態化する監視器。
class PositionIntegrityMonitor {
  final Duration separationConfirmDuration;
  final Duration ambiguousMaxDuration;
  final Duration recoveryDuration;
  PositionIntegrityState _state = PositionIntegrityState.trusted;
  Duration? _separatedSince;
  Duration? _recoverySince;

  PositionIntegrityMonitor({
    this.separationConfirmDuration = const Duration(seconds: 2),
    this.ambiguousMaxDuration = const Duration(seconds: 5),
    this.recoveryDuration = const Duration(seconds: 3),
  });

  PositionIntegrityState get state => _state;

  PositionIntegrityState observe(PositionIntegrityObservation observation) {
    if (!observation.fixIsFresh) {
      _state = PositionIntegrityState.fallback;
      _recoverySince = null;
      return _state;
    }
    final separated = observation.separationScore > 1;
    if (separated) {
      _separatedSince ??= observation.elapsed;
      final duration = observation.elapsed - _separatedSince!;
      if (observation.rawAndConservativeAgree &&
          duration >= separationConfirmDuration) {
        _state = PositionIntegrityState.fallback;
      } else if (duration >= ambiguousMaxDuration) {
        _state = PositionIntegrityState.fallback;
      } else {
        _state = observation.rawAndConservativeAgree
            ? PositionIntegrityState.suspect
            : PositionIntegrityState.ambiguous;
      }
      _recoverySince = null;
      return _state;
    }

    _separatedSince = null;
    if (_state == PositionIntegrityState.trusted) return _state;
    _recoverySince ??= observation.elapsed;
    if (observation.elapsed - _recoverySince! >= recoveryDuration) {
      _state = PositionIntegrityState.trusted;
      _recoverySince = null;
    } else {
      _state = PositionIntegrityState.reacquiring;
    }
    return _state;
  }

  void reset() {
    _state = PositionIntegrityState.trusted;
    _separatedSince = null;
    _recoverySince = null;
  }
}
