import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/rowing_motion_fusion.dart';
import 'package:rowing_navigator/services/stroke_rate_analyzer.dart';

void main() {
  List<StrokeRateSample> fixedBoatSamples({
    double spm = 24,
    double bias = 0,
    int seconds = 15,
  }) {
    final start = DateTime(2026, 8, 3, 6);
    return List.generate(seconds * 50, (index) {
      final t = index / 50.0;
      final phase = 2 * pi * spm / 60 * t;
      final surge = 0.75 * (sin(phase) + 0.28 * sin(2 * phase + 0.35)) + bias;
      return StrokeRateSample(
        timestamp: start.add(Duration(milliseconds: index * 20)),
        x: surge * 0.30,
        y: surge * -0.80,
        z: surge * 0.52,
      );
    });
  }

  void feedMotion(
    RowingMotionFusion fusion,
    List<StrokeRateSample> samples, {
    double yawRate = 0,
  }) {
    for (final sample in samples) {
      fusion
        ..addUserAcceleration(sample)
        ..addGravity(RowingGravitySample(
          timestamp: sample.timestamp,
          x: 0,
          y: 0,
          z: 9.81,
        ))
        ..addGyroscope(RowingGyroscopeSample(
          timestamp: sample.timestamp,
          x: 0,
          y: 0,
          z: yawRate,
        ));
    }
  }

  group('RowingMotionFusion', () {
    test('GPS艇速と周期加速度から1漕距離と艇速変化を算出する', () {
      final fusion = RowingMotionFusion();
      final samples = fixedBoatSamples();
      fusion.observeGnss(
        timestamp: samples.last.timestamp,
        speedMetersPerSecond: 4,
        accuracyMeters: 5,
        headingDegrees: 90,
      );
      feedMotion(fusion, samples);

      final metrics = fusion.analyze(now: samples.last.timestamp);

      expect(metrics, isNotNull);
      expect(metrics!.spm, closeTo(24, 1));
      expect(metrics.quality, RowingMotionQuality.good);
      expect(metrics.confidence, greaterThan(0.68));
      expect(metrics.distancePerStrokeMeters, closeTo(10, 1.0));
      expect(metrics.strokeSpeedRangeMetersPerSecond, greaterThan(0.2));
      expect(metrics.catchSpeedLossMetersPerSecond, greaterThanOrEqualTo(0));
      expect(metrics.lateDriveSpeedGainMetersPerSecond.isFinite, isTrue);
      expect(metrics.finishPhaseFraction, inInclusiveRange(0.12, 0.68));
      expect(metrics.recoverySpeedRetention, inInclusiveRange(0, 1));
      expect(metrics.fusedSpeedMetersPerSecond, inInclusiveRange(2.5, 5.5));
    });

    test('一定の加速度バイアスがあっても1ストロークごとに閉じる', () {
      RowingMotionMetrics analyze(double bias) {
        final fusion = RowingMotionFusion();
        final samples = fixedBoatSamples(bias: bias);
        fusion.observeGnss(
          timestamp: samples.last.timestamp,
          speedMetersPerSecond: 4,
          accuracyMeters: 5,
          headingDegrees: 0,
        );
        feedMotion(fusion, samples);
        return fusion.analyze(now: samples.last.timestamp)!;
      }

      final unbiased = analyze(0);
      final biased = analyze(0.18);

      expect(
        biased.distancePerStrokeMeters,
        closeTo(unbiased.distancePerStrokeMeters, 0.15),
      );
      expect(
        biased.strokeSpeedRangeMetersPerSecond,
        closeTo(unbiased.strokeSpeedRangeMetersPerSecond, 0.08),
      );
    });

    test('ジャイロは重力軸周りの短時間相対方位だけを更新する', () {
      final fusion = RowingMotionFusion();
      final samples = fixedBoatSamples(seconds: 15);
      feedMotion(fusion, samples.take(650).toList());
      final referenceAt = samples[649].timestamp;
      fusion.observeGnss(
        timestamp: referenceAt,
        speedMetersPerSecond: 4,
        accuracyMeters: 5,
        headingDegrees: 80,
      );
      feedMotion(
        fusion,
        samples.skip(650).toList(),
        yawRate: 5 * pi / 180,
      );

      final metrics = fusion.analyze(now: samples.last.timestamp);

      expect(metrics, isNotNull);
      expect(metrics!.fusedHeadingDegrees, closeTo(70, 1.2));
    });

    test('停止または非周期運動ではIMU艇速を作らない', () {
      final fusion = RowingMotionFusion();
      final start = DateTime(2026, 8, 3, 6);
      fusion.observeGnss(
        timestamp: start,
        speedMetersPerSecond: 0,
        accuracyMeters: 5,
      );
      for (var index = 0; index < 750; index++) {
        fusion.addUserAcceleration(StrokeRateSample(
          timestamp: start.add(Duration(milliseconds: index * 20)),
          x: 0,
          y: 0,
          z: 0,
        ));
      }

      expect(
          fusion.analyze(now: start.add(const Duration(seconds: 15))), isNull);
    });
  });

  group('RowingDistanceIntegrator', () {
    test('高信頼IMUでは位置差分と艇速積分を有界に融合する', () {
      final integrator = RowingDistanceIntegrator();
      final start = DateTime(2026, 8, 3, 6);
      integrator.add(
        timestamp: start,
        coordinateDistanceMeters: 0,
        speedMetersPerSecond: 4,
        moving: false,
      );

      final distance = integrator.add(
        timestamp: start.add(const Duration(seconds: 1)),
        coordinateDistanceMeters: 6,
        speedMetersPerSecond: 4,
        motionConfidence: 0.95,
        moving: true,
      );

      expect(distance, greaterThan(4));
      expect(distance, lessThan(6));
    });

    test('長い欠測では速度積分せず座標距離へ縮退する', () {
      final integrator = RowingDistanceIntegrator();
      final start = DateTime(2026, 8, 3, 6);
      integrator.add(
        timestamp: start,
        coordinateDistanceMeters: 0,
        speedMetersPerSecond: 4,
        moving: false,
      );

      expect(
        integrator.add(
          timestamp: start.add(const Duration(seconds: 4)),
          coordinateDistanceMeters: 15,
          speedMetersPerSecond: 4,
          motionConfidence: 1,
          moving: true,
        ),
        15,
      );
    });
  });
}
