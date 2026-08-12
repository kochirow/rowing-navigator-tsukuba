import 'package:flutter_test/flutter_test.dart';

import '../../tool/replay_estimator.dart';
import '../../tool/replay_fault_injection.dart';

void main() {
  final origin = DateTime.utc(2026, 8, 6);
  final fixes = List.generate(
      6,
      (i) => ReplayFix(
          timestamp: origin.add(Duration(seconds: i)),
          latitude: 36 + i / 100000,
          longitude: 140,
          accuracyMeters: 4,
          speedMetersPerSecond: 2,
          headingDegrees: 90));

  test('同じrecipeとseedはバイト相当の同じ結果を返す', () {
    const recipe = FaultRecipe(seed: 20260806, transforms: [
      {'id': 'batch_delivery', 'batchSize': 3},
      {'id': 'drop_burst', 'atSec': 2, 'durationSec': 1},
      {'id': 'bias_ramp', 'meters': 5},
    ]);
    String encode() => injectFaults(fixes, recipe)
        .map((it) => '${it.fix.timestamp}:${it.arrival}:${it.fix.latitude}')
        .join('|');
    expect(encode(), encode());
  });

  test('欠測・重複・速度欠損を宣言どおり作る', () {
    final dropped = injectFaults(
        fixes,
        const FaultRecipe(seed: 1, transforms: [
          {'id': 'drop_periodic', 'every': 2}
        ]));
    final duplicated = injectFaults(
        fixes,
        const FaultRecipe(seed: 1, transforms: [
          {'id': 'duplicate_fix', 'count': 1}
        ]));
    final missing = injectFaults(
        fixes,
        const FaultRecipe(seed: 1, transforms: [
          {'id': 'remote_speed_null'}
        ]));
    expect(dropped.length, lessThan(fixes.length));
    expect(duplicated.length, greaterThan(fixes.length));
    expect(missing.every((it) => it.remoteSpeedMissing), isTrue);
  });
}
