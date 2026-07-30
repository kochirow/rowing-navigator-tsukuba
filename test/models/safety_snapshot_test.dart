import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/alert_candidate.dart';
import 'package:rowing_navigator/models/safety_snapshot.dart';

void main() {
  final now = DateTime.utc(2026, 7, 15, 12);

  AlertCandidate candidate(String id) => AlertCandidate(
        alertId: id,
        detectorId: 'detector',
        category: 'hazard',
        behavior: AlertBehavior.continuousAction,
        evaluatedAt: now,
        observationId: 'observation',
      );

  SafetySnapshot snapshot({
    required int generation,
    required int revision,
    String sessionId = 'session-a',
    List<ActiveAlert>? alerts,
  }) {
    final active = alerts ?? <ActiveAlert>[];
    return SafetySnapshot(
      sessionId: sessionId,
      sessionGeneration: generation,
      revision: revision,
      evaluatedAt: now,
      runMode: SafetyRunMode.runningFull,
      capabilities: const CapabilitySnapshot(
        gpsUsable: true,
        staticProfileUsable: true,
        insideSupportedCoverage: true,
        audioUsable: true,
      ),
      activeAlerts: active,
      health: const DetectorHealthSnapshot.empty(),
      visualDirective: const VisualDirective.empty(),
      primaryAlertId: active.isEmpty ? null : active.first.candidate.alertId,
    );
  }

  test('snapshot defensively copies active alerts', () {
    final alerts = [
      ActiveAlert(candidate: candidate('a'), phase: AlertPhase.alerting),
    ];
    final value = snapshot(generation: 1, revision: 1, alerts: alerts);
    alerts.clear();

    expect(value.activeAlerts, hasLength(1));
    expect(() => value.activeAlerts.clear(), throwsUnsupportedError);
  });

  test('revision gate rejects duplicate and stale snapshots', () {
    final gate = SafetySnapshotGate();

    expect(gate.accept(snapshot(generation: 1, revision: 3)), isTrue);
    expect(gate.accept(snapshot(generation: 1, revision: 3)), isFalse);
    expect(gate.accept(snapshot(generation: 1, revision: 2)), isFalse);
    expect(gate.accept(snapshot(generation: 1, revision: 4)), isTrue);
  });

  test(
      'new generation supersedes old session but same-generation swap does not',
      () {
    final old = snapshot(generation: 1, revision: 99);

    expect(
      snapshot(
        generation: 2,
        revision: 0,
        sessionId: 'session-b',
      ).supersedes(old),
      isTrue,
    );
    expect(
      snapshot(
        generation: 1,
        revision: 100,
        sessionId: 'session-b',
      ).supersedes(old),
      isFalse,
    );
  });
}
