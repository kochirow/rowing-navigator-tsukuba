import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/services/bounded_position_set.dart';
import 'package:rowing_navigator/services/conservative_position_estimator.dart';

void main() {
  ConservativeFix fix({
    required int seconds,
    required double latitude,
    double speed = 4,
  }) =>
      ConservativeFix(
        position: LatLng(latitude, 140),
        timestamp: DateTime.utc(2026, 8, 6, 12).add(Duration(seconds: seconds)),
        elapsed: Duration(seconds: seconds),
        accuracyMeters: 4,
        speedMetersPerSecond: speed,
        headingDegrees: 0,
      );

  test('代表点は定速時も生fixそのもので前方へ外挿しない', () {
    final estimator = ConservativePositionEstimator();
    estimator.update(fix: fix(seconds: 0, latitude: 36));
    final output =
        estimator.update(fix: fix(seconds: 1, latitude: 36.00001)).output!;
    expect(output.representativePoint.latitude, 36.00001);
  });

  test('欠測中は代表点を動かさず、集合だけを前方へ伸ばす', () {
    final estimator = ConservativePositionEstimator();
    estimator.update(fix: fix(seconds: 0, latitude: 36));
    final current =
        estimator.update(fix: fix(seconds: 1, latitude: 36.00001)).output!;
    final predicted = estimator.predict(elapsed: const Duration(seconds: 4))!;
    expect(predicted.representativePoint, current.representativePoint);
    expect(predicted.safetySet.boundingRadiusMeters,
        greaterThan(current.safetySet.boundingRadiusMeters));
  });

  test('物理的に届かない単発50m飛びを棄却する', () {
    final estimator = ConservativePositionEstimator();
    estimator.update(fix: fix(seconds: 0, latitude: 36));
    final result = estimator.update(fix: fix(seconds: 1, latitude: 36.0005));
    expect(result.accepted, isFalse);
    expect(result.output!.representativePoint.latitude, 36);
  });

  test('航行中の集合はカプセルで、横方向に前方距離ほど膨らまない', () {
    final estimator = ConservativePositionEstimator();
    estimator.update(fix: fix(seconds: 0, latitude: 36));
    estimator.update(fix: fix(seconds: 1, latitude: 36.00001));
    final predicted = estimator.predict(elapsed: const Duration(seconds: 4))!;
    expect(predicted.safetySet, isA<CapsuleSet>());
  });
}
