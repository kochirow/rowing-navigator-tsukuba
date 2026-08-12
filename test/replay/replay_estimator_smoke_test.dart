import 'package:flutter_test/flutter_test.dart';

import '../../tool/replay_estimator.dart';

void main() {
  final origin = DateTime.utc(2026, 8, 6);
  ReplayFix fix(int second, double lat,
          {double speed = 2, double heading = 90}) =>
      ReplayFix(
        timestamp: origin.add(Duration(seconds: second)),
        latitude: lat,
        longitude: 140,
        accuracyMeters: 4,
        speedMetersPerSecond: speed,
        headingDegrees: heading,
      );

  test('S0はraw fixをそのまま代表点へ使う', () {
    final fixes = [fix(0, 36), fix(1, 36.00001), fix(2, 36.00002, speed: 0)];
    final run = replayFixes(fixes, [S0RawSolution()]);
    final output = run.outputs['s0_raw']!;
    expect(output.map((it) => it.representativePoint.latitude),
        [36, 36.00001, 36.00002]);
    expect(output.last.speedMetersPerSecond, 0);
  });

  test('S1はraw入力から推定し、filtered列を入力に使わない', () {
    final raw = fix(0, 36);
    final shiftedRecordedFiltered = ReplayFix(
      timestamp: raw.timestamp,
      latitude: raw.latitude,
      longitude: raw.longitude,
      accuracyMeters: raw.accuracyMeters,
      speedMetersPerSecond: raw.speedMetersPerSecond,
      headingDegrees: raw.headingDegrees,
      recordedFilteredLatitude: 37,
      recordedFilteredLongitude: 141,
    );
    final output = replayFixes([shiftedRecordedFiltered], [S1KalmanSolution()])
        .outputs['s1_kalman']!
        .single;
    expect(output.representativePoint.latitude, closeTo(36, 1e-9));
    expect(output.representativePoint.longitude, closeTo(140, 1e-9));
  });

  test('Stage 2比較用のS1参照は実機記録のfiltered値を使う', () {
    final recorded = ReplayFix(
      timestamp: origin,
      latitude: 36,
      longitude: 140,
      accuracyMeters: 4,
      recordedFilteredLatitude: 36.001,
      recordedFilteredLongitude: 140.001,
    );
    final output = replayFixes([recorded], [S1RecordedSolution()])
        .outputs['s1_recorded']!
        .single;
    expect(output.representativePoint.latitude, 36.001);
    expect(output.representativePoint.longitude, 140.001);
  });
}
