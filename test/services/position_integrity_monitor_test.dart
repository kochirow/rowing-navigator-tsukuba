import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/position_integrity_monitor.dart';

void main() {
  PositionIntegrityObservation observation(int seconds,
          {bool separated = false}) =>
      PositionIntegrityObservation(
        elapsed: Duration(seconds: seconds),
        separationMeters: separated ? 20 : 1,
        protectionS1Meters: 4,
        protectionConsensusMeters: 4,
        motionAllowanceMeters: 1,
        rawAndConservativeAgree: true,
        fixIsFresh: true,
      );

  test('S1だけが分離し続けるとfallbackへ移る', () {
    final monitor = PositionIntegrityMonitor();
    expect(monitor.observe(observation(0, separated: true)),
        PositionIntegrityState.suspect);
    expect(monitor.observe(observation(2, separated: true)),
        PositionIntegrityState.fallback);
  });

  test('fallbackから即trustedへ戻らず、回復時間を待つ', () {
    final monitor = PositionIntegrityMonitor();
    monitor.observe(observation(0, separated: true));
    monitor.observe(observation(2, separated: true));
    expect(monitor.observe(observation(3)), PositionIntegrityState.reacquiring);
    expect(monitor.observe(observation(6)), PositionIntegrityState.trusted);
  });

  test('古いfixではtrustedを維持しない', () {
    final monitor = PositionIntegrityMonitor();
    final stale = PositionIntegrityObservation(
      elapsed: const Duration(seconds: 1),
      separationMeters: 0,
      protectionS1Meters: 1,
      protectionConsensusMeters: 1,
      motionAllowanceMeters: 0,
      rawAndConservativeAgree: true,
      fixIsFresh: false,
    );
    expect(monitor.observe(stale), PositionIntegrityState.fallback);
  });

  test('判断不能な分離も5秒を超えて保持しない', () {
    final monitor = PositionIntegrityMonitor();
    PositionIntegrityObservation ambiguous(int seconds) =>
        PositionIntegrityObservation(
          elapsed: Duration(seconds: seconds),
          separationMeters: 20,
          protectionS1Meters: 4,
          protectionConsensusMeters: 4,
          motionAllowanceMeters: 1,
          rawAndConservativeAgree: false,
          fixIsFresh: true,
        );
    expect(monitor.observe(ambiguous(0)), PositionIntegrityState.ambiguous);
    expect(monitor.observe(ambiguous(5)), PositionIntegrityState.fallback);
  });
}
