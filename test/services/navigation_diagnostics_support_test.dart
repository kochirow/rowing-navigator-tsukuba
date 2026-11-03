import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/risk_evaluator_config.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import 'package:rowing_navigator/models/session_model.dart';
import 'package:rowing_navigator/services/navigation_diagnostics_support.dart';
import 'package:rowing_navigator/types/boat_type.dart';

Boat _boat(double speed) => Boat(
      boatId: 'b',
      boatType: BoatType.r_1x,
      lat: 36,
      lng: 140,
      heading: 90,
      speed: speed,
      timestamp: DateTime.utc(2026, 11, 4),
    );

Session _session(List<SessionDiagnosticEvent> events) {
  final start = DateTime.utc(2026, 11, 3, 21);
  return Session(
    id: 's',
    startedAt: start,
    endedAt: start.add(const Duration(minutes: 40)),
    boatTypeName: '4+',
    seatPosLabel: 'cox',
    points: const [],
    summary: SessionSummary(
      totalDistanceMeters: 0,
      durationSec: 0,
      maxSpeed: 0,
      avgSpeed: 0,
      splits: const [],
      pieces: const [],
      alertCounts: const {},
    ),
    diagnosticEvents: events,
    isComplete: false,
  );
}

void main() {
  group('他艇の警告に添える相手の動き(R8-R1)', () {
    test('評価と同じ規則で方位の信頼を決める', () {
      final slow = otherBoatTargetDiagnostics(
          _boat(shipDomainReliableHeadingSpeedMetersPerSecond - 0.1));
      final fast = otherBoatTargetDiagnostics(
          _boat(shipDomainReliableHeadingSpeedMetersPerSecond));
      expect(slow.headingReliable, isFalse);
      expect(fast.headingReliable, isTrue);
      expect(fast.speedMps, shipDomainReliableHeadingSpeedMetersPerSecond);
    });

    test('相手が一覧に無ければ値を作らない', () {
      final none = otherBoatTargetDiagnostics(null);
      expect(none.speedMps, isNull);
      expect(none.headingReliable, isNull);
    });
  });

  group('途切れた記録の最後の様子(R8-R2)', () {
    test('最後のライフサイクル・電池・温度・メモリ警告を拾う', () {
      final t0 = DateTime.utc(2026, 11, 3, 21, 10);
      final context = sessionRecoveryContext(_session([
        SessionDiagnosticEvent(
            t: t0,
            type: 'battery_level_changed',
            details: {'levelPercent': 80}),
        SessionDiagnosticEvent(
            t: t0.add(const Duration(minutes: 1)),
            type: 'gps_environment_snapshot',
            details: {'thermalState': 'fair', 'lowPowerModeEnabled': false}),
        SessionDiagnosticEvent(
            t: t0.add(const Duration(minutes: 2)),
            type: 'memory_pressure',
            details: {'lifecycle': 'paused'}),
        SessionDiagnosticEvent(
            t: t0.add(const Duration(minutes: 3)),
            type: 'app_lifecycle_changed',
            details: {'from': 'resumed', 'to': 'paused'}),
        SessionDiagnosticEvent(
            t: t0.add(const Duration(minutes: 4)),
            type: 'battery_level_changed',
            details: {'levelPercent': 74}),
        SessionDiagnosticEvent(
            t: t0.add(const Duration(minutes: 5)),
            type: 'diagnostic_heartbeat',
            details: {'lifecycle': 'hidden'}),
      ]));
      expect(context['lastLifecycle'], 'hidden');
      expect(context['lastBatteryPercent'], 74);
      expect(context['lastThermalState'], 'fair');
      expect(context['lastLowPowerModeEnabled'], isFalse);
      expect(context['memoryPressureCount'], 1);
      expect(context['lastMemoryPressureAt'],
          t0.add(const Duration(minutes: 2)).toIso8601String());
    });

    test('手がかりが無ければ null のまま残す(メモリ警告の回数だけは0と数えられる)', () {
      final context = sessionRecoveryContext(_session(const []));
      expect(context['lastLifecycle'], isNull);
      expect(context['lastBatteryPercent'], isNull);
      expect(context['lastThermalState'], isNull);
      expect(context['memoryPressureCount'], 0);
      expect(context['lastMemoryPressureAt'], isNull);
    });
  });
}
