import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/services/conservative_position_estimator.dart';
import 'package:rowing_navigator/services/motion_fusion_base.dart';

void main() {
  const metersPerDegree = 111195.0;
  ConservativeFix fix(int s, {bool stuck = true}) => ConservativeFix(
        position: LatLng(36 + s * 2.6 / metersPerDegree, 140),
        timestamp: DateTime.utc(2026, 10, 27, 6).add(Duration(seconds: s)),
        elapsed: Duration(seconds: s),
        accuracyMeters: 4,
        speedMetersPerSecond: stuck ? 0.6 : 2.6,
        headingDegrees: stuck ? 270 : 0,
        speedAccuracyMetersPerSecond: stuck ? 3.75 : 0.4,
        headingAccuracyDegrees: stuck ? 180 : 8,
      );

  test('GNSSが使えるときは従来どおりGNSSの速度・方位を基準にする', () {
    final base = FusionBase.select(
      speedMetersPerSecond: 2.6,
      speedAccuracyMetersPerSecond: 0.4,
      headingDegrees: 10,
      headingAccuracyDegrees: 8,
      conservativeResult: null,
    )!;
    expect(base.source, GnssMotionSource.gnss);
    expect(base.speedMetersPerSecond, 2.6);
    expect(base.headingDegrees, 10);
    expect(base.speedAccuracyMetersPerSecond, isNull);
  });

  test('速度精度3.75m/sの間は位置の変化から求めた速度と、代わりの精度を渡す', () {
    final estimator = ConservativePositionEstimator();
    ConservativeUpdateResult? result;
    for (var s = 0; s < 6; s++) {
      result = estimator.update(fix: fix(s));
    }
    final base = FusionBase.select(
      speedMetersPerSecond: 0.6,
      speedAccuracyMetersPerSecond: 3.75,
      headingDegrees: 270,
      headingAccuracyDegrees: 180,
      conservativeResult: result,
    )!;
    expect(base.source, GnssMotionSource.position);
    expect(base.speedMetersPerSecond, closeTo(2.6, 0.05));
    expect(base.speedAccuracyMetersPerSecond, 1.0);
    // 止まった270°ではなく、位置の変化から求めた北向き
    expect(base.headingDegrees, closeTo(0, 1));
  });

  test('最初の測位で位置由来の速度が無ければ基準を更新しない', () {
    final estimator = ConservativePositionEstimator();
    final result = estimator.update(fix: fix(0));
    expect(
      FusionBase.select(
        speedMetersPerSecond: 0.6,
        speedAccuracyMetersPerSecond: 3.75,
        headingDegrees: 270,
        headingAccuracyDegrees: 180,
        conservativeResult: result,
      ),
      isNull,
    );
  });
}
