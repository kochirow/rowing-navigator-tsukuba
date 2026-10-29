import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/services/bounded_position_set.dart';
import 'package:rowing_navigator/services/conservative_position_estimator.dart';
import 'package:rowing_navigator/services/gnss_motion_validity.dart';

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

  group('iOSが方位を出せない状態(方位精度180°・速度精度3.75m/s)', () {
    // 北へ2.6m/sで進む艇。1度の緯度 ≒ 111195m。
    const metersPerDegree = 111195.0;
    const trueSpeed = 2.6;
    ConservativeFix rowing({
      required int seconds,
      double speed = trueSpeed,
      double heading = 0,
      double speedAccuracy = 0.4,
      double headingAccuracy = 8,
      double? meters,
    }) =>
        ConservativeFix(
          position: LatLng(
              36 + (meters ?? seconds * trueSpeed) / metersPerDegree, 140),
          timestamp:
              DateTime.utc(2026, 10, 27, 6).add(Duration(seconds: seconds)),
          elapsed: Duration(seconds: seconds),
          accuracyMeters: 4,
          speedMetersPerSecond: speed,
          headingDegrees: heading,
          speedAccuracyMetersPerSecond: speedAccuracy,
          headingAccuracyDegrees: headingAccuracy,
        );

    test('止まった方位(270°)を使わず、位置の変化から北向きを保つ', () {
      final estimator = ConservativePositionEstimator();
      for (var s = 0; s < 5; s++) {
        estimator.update(fix: rowing(seconds: s));
      }
      ConservativeSolutionOutput? output;
      for (var s = 5; s < 20; s++) {
        output = estimator
            .update(
              fix: rowing(
                seconds: s,
                speed: 0.6,
                heading: 270,
                speedAccuracy: 3.75,
                headingAccuracy: 180,
              ),
            )
            .output;
      }
      final heading = output!.headingDegrees;
      final error = ((heading - 0 + 540) % 360) - 180;
      expect(error.abs(), lessThan(1));
      expect(output.headingSource, GnssMotionSource.position);
      expect(output.headingReliable, isTrue);
    });

    test('速度はiOSの約1/4の値ではなく実際の速さに追従する', () {
      final estimator = ConservativePositionEstimator();
      ConservativeSolutionOutput? output;
      for (var s = 0; s < 15; s++) {
        output = estimator
            .update(
              fix: rowing(
                seconds: s,
                speed: 0.6,
                speedAccuracy: 3.75,
                headingAccuracy: 180,
              ),
            )
            .output;
      }
      expect(output!.speedMetersPerSecond, closeTo(trueSpeed, 0.1));
      expect(output.speedSource, GnssMotionSource.position);
      expect(output.observedSpeedMetersPerSecond, closeTo(trueSpeed, 0.05));
    });

    test('最初の測位から状態に入っていても、方位の初期値0°を信頼しない', () {
      final estimator = ConservativePositionEstimator();
      final output = estimator
          .update(
            fix: rowing(
              seconds: 0,
              speed: 0.6,
              heading: 270,
              speedAccuracy: 3.75,
              headingAccuracy: 180,
            ),
          )
          .output!;
      expect(output.headingReliable, isFalse);
      expect(output.headingSource, GnssMotionSource.held);
      expect(output.speedSource, GnssMotionSource.held);
    });

    test('1秒1.5m未満の移動が3秒を超えて続くと方位を信頼しない', () {
      final estimator = ConservativePositionEstimator();
      for (var s = 0; s < 5; s++) {
        estimator.update(fix: rowing(seconds: s));
      }
      final reliability = <bool>[];
      for (var s = 5; s < 12; s++) {
        reliability.add(estimator
            .update(
              fix: rowing(
                seconds: s,
                speed: 0.6,
                heading: 270,
                speedAccuracy: 3.75,
                headingAccuracy: 180,
                // 1.2m/s: 方位は更新できないが停止ではない
                meters: 4 * trueSpeed + (s - 4) * 1.2,
              ),
            )
            .output!
            .headingReliable);
      }
      // 最後の更新は4秒目のGNSS方位。7秒目(3秒後)までは信頼し、その後は落ちる。
      expect(reliability.take(3), everyElement(isTrue));
      expect(reliability.skip(3), everyElement(isFalse));
    });

    test('精度不明(0以下)の値は今までどおりGNSSの値を使う', () {
      final estimator = ConservativePositionEstimator();
      ConservativeSolutionOutput? output;
      for (var s = 0; s < 3; s++) {
        output = estimator
            .update(
              fix: rowing(
                seconds: s,
                speed: 2,
                heading: 10,
                speedAccuracy: 0,
                headingAccuracy: -1,
              ),
            )
            .output;
      }
      expect(output!.speedSource, GnssMotionSource.gnss);
      expect(output.headingSource, GnssMotionSource.gnss);
      expect(output.headingDegrees, closeTo(10, 1e-9));
    });

    test('OSがまとめて渡した測位でも、速度は測位時刻の差で求める', () {
      final estimator = ConservativePositionEstimator();
      estimator.update(
          fix: rowing(seconds: 0, speedAccuracy: 3.75, headingAccuracy: 180));
      final second =
          rowing(seconds: 1, speedAccuracy: 3.75, headingAccuracy: 180);
      // 処理時刻は20msしか離れていない
      final batched = ConservativeFix(
        position: second.position,
        timestamp: second.timestamp,
        elapsed: const Duration(milliseconds: 20),
        accuracyMeters: second.accuracyMeters,
        speedMetersPerSecond: second.speedMetersPerSecond,
        headingDegrees: second.headingDegrees,
        speedAccuracyMetersPerSecond: second.speedAccuracyMetersPerSecond,
        headingAccuracyDegrees: second.headingAccuracyDegrees,
      );
      final output = estimator.update(fix: batched).output!;
      expect(output.observedSpeedMetersPerSecond, closeTo(trueSpeed, 0.05));
    });
  });
}
