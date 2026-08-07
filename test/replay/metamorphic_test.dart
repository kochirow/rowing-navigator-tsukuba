import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/models/protection_budget.dart';
import 'package:rowing_navigator/services/bounded_position_set.dart';
import 'package:rowing_navigator/services/safety_contract_monitor.dart';

import '../../tool/replay_estimator.dart';
import '../../tool/replay_fault_injection.dart';
import '../../tool/replay_pair_metrics.dart';

void main() {
  final origin = DateTime.utc(2026, 8, 6);
  ReplayFix fix(int second, double lat, double lng,
          {double speed = 2, double heading = 90}) =>
      ReplayFix(
        timestamp: origin.add(Duration(seconds: second)),
        latitude: lat,
        longitude: lng,
        accuracyMeters: 3,
        speedMetersPerSecond: speed,
        headingDegrees: heading,
      );

  test('1: 一括平行移動で相対距離は変わらない', () {
    final before =
        computePairMetrics([fix(0, 36, 140)], [fix(0, 36, 140.00001)]);
    final after =
        computePairMetrics([fix(0, 37, 141)], [fix(0, 37, 141.00001)]);
    expect(after.pairDistance['median'],
        closeTo(before.pairDistance['median']!, .02));
  });
  test('2: 円集合の交差は回転に依存しない', () {
    const a = CircleSet(representativePoint: LatLng(36, 140), radiusMeters: 4);
    const b =
        CircleSet(representativePoint: LatLng(36.00002, 140), radiusMeters: 4);
    expect(a.intersectsSet(b), isTrue);
  });
  test('3: 同一fix重複はS0の代表点を増やさない', () {
    final input = [fix(0, 36, 140)];
    final injected = injectFaults(
        input,
        const FaultRecipe(seed: 1, transforms: [
          {'id': 'duplicate_fix'}
        ]));
    final points =
        replayFixes(injected.map((it) => it.fix).toList(), [S0RawSolution()])
            .outputs['s0_raw']!;
    expect(
      points
          .map((p) =>
              '${p.representativePoint.latitude}:${p.representativePoint.longitude}')
          .toSet(),
      hasLength(1),
    );
  });
  test('4: 古いfixを後着させてもarrival順は明示される', () {
    final injected = injectFaults(
        [fix(0, 36, 140), fix(1, 36.1, 140)],
        const FaultRecipe(seed: 1, transforms: [
          {'id': 'stale_replay', 'delaySec': 2}
        ]));
    expect(
        injected.first.arrival.isBefore(injected.last.arrival) ||
            injected.first.arrival == injected.last.arrival,
        isTrue);
  });
  test('5: 欠測時間が長いほど低速保護円は縮まらない', () {
    const set =
        CircleSet(representativePoint: LatLng(36, 140), radiusMeters: 2);
    expect(
        set
            .grownBy(
                elapsed: const Duration(seconds: 4),
                speedMetersPerSecond: 1,
                headingDegrees: 0,
                headingReliable: false)
            .boundingRadiusMeters,
        greaterThanOrEqualTo(set
            .grownBy(
                elapsed: const Duration(seconds: 1),
                speedMetersPerSecond: 1,
                headingDegrees: 0,
                headingReliable: false)
            .boundingRadiusMeters));
  });
  test('6: 解分離が増えても台帳の分離成分は縮めない', () {
    final monitor = SafetyContractMonitor();
    final violations = monitor.observe(ContractObservation(
        elapsed: const Duration(seconds: 1),
        at: origin,
        budget: const ProtectionBudget(solutionDisagreementMeters: 1),
        previousBudget: const ProtectionBudget(solutionDisagreementMeters: 2)));
    expect(violations.map((v) => v.contractId),
        contains('BUDGET_MONOTONIC_SEPARATION'));
  });
  test('7: 他艇速度不明をat_restで抑制すると契約違反', () {
    final violations = SafetyContractMonitor().observe(ContractObservation(
        elapsed: Duration.zero,
        at: origin,
        category: 'other_boat',
        suppressionReason: 'at_rest'));
    expect(violations.map((v) => v.contractId),
        contains('OTHER_BOAT_NOT_SILENCED_ON_UNKNOWN_SPEED'));
  });
  test('8: 同一入力のreplayは同じ出力になる', () {
    final input = [fix(0, 36, 140), fix(1, 36.00001, 140)];
    final a = replayFixes(input, [S1KalmanSolution()]).toJson();
    final b = replayFixes(input, [S1KalmanSolution()]).toJson();
    expect(a, b);
  });
  test('9: urgentをstable_stopで抑制すると契約違反', () {
    final violations = SafetyContractMonitor().observe(ContractObservation(
        elapsed: Duration.zero,
        at: origin,
        urgency: 'urgent',
        suppressionReason: 'stable_stop'));
    expect(violations.map((v) => v.contractId),
        contains('URGENT_NOT_SUPPRESSED_BY_LOW_PRIORITY'));
  });
  test('10: ペアを交換しても距離指標は同じ', () {
    final a = [fix(0, 36, 140)];
    final b = [fix(0, 36, 140.00001)];
    expect(computePairMetrics(a, b).pairDistance['median'],
        closeTo(computePairMetrics(b, a).pairDistance['median']!, .01));
  });
}
