import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/gnss_motion_validity.dart';

void main() {
  GnssMotionValidity evaluate({
    double? speed = 3,
    double? speedAccuracy = 0.4,
    double? heading = 90,
    double? headingAccuracy = 10,
  }) =>
      GnssMotionValidity.evaluate(
        speedMetersPerSecond: speed,
        speedAccuracyMetersPerSecond: speedAccuracy,
        headingDegrees: heading,
        headingAccuracyDegrees: headingAccuracy,
      );

  test('正常な精度なら速度・方位とも使う', () {
    final v = evaluate();
    expect(v.speedUsable, isTrue);
    expect(v.headingUsable, isTrue);
    expect(v.speedReason, GnssMotionRejectReason.none);
  });

  test('iOSが方位を出せない状態(方位精度180°・速度精度3.75m/s)は両方使わない', () {
    final v = evaluate(speed: 0.6, speedAccuracy: 3.75, headingAccuracy: 180);
    expect(v.speedUsable, isFalse);
    expect(v.headingUsable, isFalse);
    expect(v.speedReason, GnssMotionRejectReason.accuracy);
    expect(v.headingReason, GnssMotionRejectReason.accuracy);
  });

  test('速度と方位は別々に判定する', () {
    final headingOnly = evaluate(headingAccuracy: 179);
    expect(headingOnly.speedUsable, isTrue);
    expect(headingOnly.headingUsable, isFalse);
    final speedOnly = evaluate(speedAccuracy: 3.0);
    expect(speedOnly.speedUsable, isFalse);
    expect(speedOnly.headingUsable, isTrue);
  });

  test('正常時の上側(速度精度2.55m/s・方位精度119°)は使う', () {
    final v = evaluate(speedAccuracy: 2.55, headingAccuracy: 119);
    expect(v.speedUsable, isTrue);
    expect(v.headingUsable, isTrue);
  });

  test('負の方位・負の速度・非有限は値が無効', () {
    final v = evaluate(speed: -1, heading: -1);
    expect(v.speedUsable, isFalse);
    expect(v.headingUsable, isFalse);
    expect(v.speedReason, GnssMotionRejectReason.invalidValue);
    expect(v.headingReason, GnssMotionRejectReason.invalidValue);
    expect(evaluate(speed: double.nan).speedUsable, isFalse);
    expect(evaluate(heading: 360).headingUsable, isFalse);
    expect(evaluate(heading: null).headingUsable, isFalse);
  });

  test('精度が0以下・非有限(精度不明)なら今までどおり値を使う', () {
    for (final unknown in [0.0, -1.0, double.nan, null]) {
      final v = evaluate(speedAccuracy: unknown, headingAccuracy: unknown);
      expect(v.speedUsable, isTrue, reason: '$unknown');
      expect(v.headingUsable, isTrue, reason: '$unknown');
      expect(v.speedAccuracyKnown, isFalse);
      expect(v.headingAccuracyKnown, isFalse);
    }
  });
}
