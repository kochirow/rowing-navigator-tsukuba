import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/models/protection_budget.dart';
import 'package:rowing_navigator/services/conservative_position_estimator.dart';
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

  group('台帳の単調性は同じ測位から外挿した台帳どうしで比べる', () {
    ConservativeFix fix(int seconds) => ConservativeFix(
          position: LatLng(36 + seconds * 0.00001, 140),
          timestamp: now.add(Duration(seconds: seconds)),
          elapsed: Duration(seconds: seconds),
          accuracyMeters: 4,
          speedMetersPerSecond: 4,
          headingDegrees: 0,
        );

    test('測位時の台帳(解分離あり)と外挿台帳を比べて誤検出しない', () {
      // 2026-09-26 の実機ログ: 測位時に解分離2mの台帳を記録した直後、
      // 解分離を持たない外挿台帳と比べて毎回「縮んだ」と記録していた。
      final estimator = ConservativePositionEstimator();
      estimator.update(fix: fix(0));
      final stale = estimator.predict(elapsed: const Duration(seconds: 2))!;
      final monitor = SafetyContractMonitor();
      final previous = comparablePreviousStaleBudget(
        previous: null,
        currentSolutionTimestamp: stale.timestamp,
      );
      final violations = monitor.observe(observation(
        seconds: 2,
        budget: stale.budget,
        previousBudget: previous,
      ));
      expect(violations, isEmpty);
    });

    test('新しい測位で作り直した台帳とは比べない', () {
      final estimator = ConservativePositionEstimator();
      estimator.update(fix: fix(0));
      final first = estimator.predict(elapsed: const Duration(seconds: 3))!;
      estimator.update(fix: fix(4));
      final second = estimator.predict(elapsed: const Duration(seconds: 5))!;
      expect(
        comparablePreviousStaleBudget(
          previous: StaleProtectionBudgetSample(
            solutionTimestamp: first.timestamp,
            budget: first.budget,
          ),
          currentSolutionTimestamp: second.timestamp,
        ),
        isNull,
      );
    });

    test('同じ測位からの外挿どうしは比べ、本当に縮めば検出する', () {
      final estimator = ConservativePositionEstimator();
      estimator.update(fix: fix(0));
      final earlier = estimator.predict(elapsed: const Duration(seconds: 1))!;
      final later = estimator.predict(elapsed: const Duration(seconds: 3))!;
      final sample = StaleProtectionBudgetSample(
        solutionTimestamp: earlier.timestamp,
        budget: earlier.budget,
      );
      final comparable = comparablePreviousStaleBudget(
        previous: sample,
        currentSolutionTimestamp: later.timestamp,
      );
      expect(comparable, same(earlier.budget));
      expect(
        SafetyContractMonitor().observe(observation(
          budget: later.budget,
          previousBudget: comparable,
        )),
        isEmpty,
      );
      // 同じ測位なのに縮んだ台帳は、従来どおり違反として残す。
      expect(
        SafetyContractMonitor()
            .observe(observation(
              budget: earlier.budget.copyWith(fixAgeMotionMeters: 0),
              previousBudget: later.budget,
            ))
            .map((v) => v.contractId),
        contains('BUDGET_MONOTONIC_FIX_AGE'),
      );
    });
  });
}
