import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/protection_budget.dart';
import 'package:rowing_navigator/services/safety_contract_monitor.dart';

void main() {
  final now = DateTime.utc(2026, 8, 6);
  ContractObservation observation({
    int seconds = 0,
    DateTime? accepted,
    DateTime? previous,
    double? radius,
    bool fixUpdated = false,
    String? category,
    double? remoteSpeed,
    String? suppression,
    String? urgency,
    bool repeated = false,
    bool worsened = false,
    ProtectionBudget? budget,
    ProtectionBudget? previousBudget,
  }) =>
      ContractObservation(
        elapsed: Duration(seconds: seconds),
        at: now.add(Duration(seconds: seconds)),
        acceptedFixTimestamp: accepted,
        previousAcceptedFixTimestamp: previous,
        protectionRadiusMeters: radius,
        fixUpdatedThisTick: fixUpdated,
        category: category,
        remoteSpeedMetersPerSecond: remoteSpeed,
        suppressionReason: suppression,
        urgency: urgency,
        audioRepeated: repeated,
        urgencyWorsened: worsened,
        budget: budget,
        previousBudget: previousBudget,
      );

  test('時刻逆行・停滞中の半径縮小・欠損速度の静音を検出する', () {
    final monitor = SafetyContractMonitor();
    expect(
      monitor.observe(observation(
          accepted: now, previous: now.add(const Duration(seconds: 1)))),
      isNotEmpty,
    );
    monitor.observe(observation(radius: 5));
    final violations = monitor.observe(observation(
      radius: 4,
      category: 'other_boat',
      suppression: 'at_rest',
    ));
    expect(
        violations.map((v) => v.contractId),
        containsAll(<String>[
          'PROTECTION_NEVER_SHRINKS_WHILE_STALE',
          'OTHER_BOAT_NOT_SILENCED_ON_UNKNOWN_SPEED',
        ]));
  });

  test('正常な更新と、悪化に伴う再生は違反にしない', () {
    final monitor = SafetyContractMonitor();
    final violations = monitor.observe(observation(
      radius: 3,
      fixUpdated: true,
      category: 'other_boat',
      remoteSpeed: 2,
      urgency: 'urgent',
      repeated: true,
      worsened: true,
      budget: const ProtectionBudget(fixAgeMotionMeters: 2),
      previousBudget: const ProtectionBudget(fixAgeMotionMeters: 1),
    ));
    expect(violations, isEmpty);
  });
}
