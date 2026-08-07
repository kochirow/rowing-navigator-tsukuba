import 'package:flutter_test/flutter_test.dart';

import '../../tool/replay_estimator.dart';
import '../../tool/replay_pair_metrics.dart';

void main() {
  final origin = DateTime.utc(2026, 8, 6);
  ReplayFix point(int seconds, double lat, double lng,
          {double heading = 90, double speed = 2}) =>
      ReplayFix(
        timestamp: origin.add(Duration(seconds: seconds)),
        latitude: lat,
        longitude: lng,
        accuracyMeters: 3,
        headingDegrees: heading,
        speedMetersPerSecond: speed,
      );

  test('0.6秒以内の最近傍を組にし、沿・横分解を行う', () {
    final metrics = computePairMetrics(
      [point(0, 36, 140), point(1, 36, 140.00001)],
      [point(0, 36, 140.00001), point(1, 36, 140.00002)],
    );
    expect(metrics.pairCount, 2);
    expect(metrics.pairDistance['median'], greaterThan(0));
    expect(metrics.alongCross['absoluteAlongMedian'], greaterThan(0));
    expect(metrics.alongCross['absoluteCrossMedian'], lessThan(0.1));
  });
}
