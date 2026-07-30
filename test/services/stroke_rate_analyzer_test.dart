import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/stroke_rate_config.dart';
import 'package:rowing_navigator/services/stroke_rate_analyzer.dart';

void main() {
  final analyzer = StrokeRateAnalyzer();

  /// 艇体に固定した端末の、任意の取付方向を模した3軸加速度波形。
  List<StrokeRateSample> makeBoatFixedSamples({
    required double spm,
    required int seconds,
    required (double, double, double) direction,
    bool irregularSampling = false,
    double amplitude = 0.8,
  }) {
    final samples = <StrokeRateSample>[];
    var elapsedSeconds = 0.0;
    var index = 0;
    final start = DateTime(2026, 7, 24, 6);
    while (elapsedSeconds < seconds) {
      final phase = 2 * pi * spm / 60 * elapsedSeconds;
      // ドライブとリカバリーで非対称な、実艇に近い符号付き加速度。
      final stroke = amplitude * (sin(phase) + 0.25 * sin(2 * phase + 0.4));
      final vibration = 0.055 * sin(2 * pi * 7.1 * elapsedSeconds);
      samples.add(StrokeRateSample(
        timestamp: start.add(Duration(
          microseconds:
              (elapsedSeconds * Duration.microsecondsPerSecond).round(),
        )),
        x: direction.$1 * stroke + vibration,
        y: direction.$2 * stroke - vibration * 0.7,
        z: direction.$3 * stroke + vibration * 0.35,
      ));
      final jitter = irregularSampling ? 1 + 0.22 * sin(index * 1.7) : 1;
      elapsedSeconds += spmSamplingMs / 1000 * jitter;
      index++;
    }
    return samples;
  }

  group('estimate (艇体固定・3軸)', () {
    test('要求サンプリング周期は50Hzである', () {
      expect(1000 / spmSamplingMs, 50);
    });

    test('任意の端末向きでも18spmを推定する', () {
      final estimate = analyzer.estimate(makeBoatFixedSamples(
        spm: 18,
        seconds: 15,
        direction: (0.27, -0.71, 0.65),
      ));

      expect(estimate, isNotNull);
      expect(estimate!.spm, closeTo(18, 0.8));
      expect(estimate.confidence, greaterThanOrEqualTo(spmMinimumConfidence));
    });

    test('不規則な実サンプル時刻でも36spmを推定する', () {
      final estimate = analyzer.estimate(makeBoatFixedSamples(
        spm: 36,
        seconds: 15,
        direction: (-0.54, 0.18, 0.82),
        irregularSampling: true,
      ));

      expect(estimate, isNotNull);
      expect(estimate!.spm, closeTo(36, 1.2));
    });

    test('高レート52spmでも二重カウントしない', () {
      final estimate = analyzer.estimate(makeBoatFixedSamples(
        spm: 52,
        seconds: 15,
        direction: (0.91, 0.22, -0.35),
      ));

      expect(estimate, isNotNull);
      expect(estimate!.spm, closeTo(52, 1.5));
    });

    test('停止中は推定値を出さない', () {
      final start = DateTime(2026, 7, 24, 6);
      final samples = List.generate(
        750,
        (index) => StrokeRateSample(
          timestamp: start.add(Duration(milliseconds: index * 20)),
          x: 0,
          y: 0,
          z: 0,
        ),
      );

      expect(analyzer.estimate(samples), isNull);
    });

    test('不規則な手持ち振動は低信頼として棄却する', () {
      final start = DateTime(2026, 7, 24, 6);
      final samples = List.generate(750, (index) {
        final t = index * 0.02;
        return StrokeRateSample(
          timestamp: start.add(Duration(milliseconds: index * 20)),
          x: 0.35 * sin(2 * pi * (0.2 + (index % 11) * 0.07) * t),
          y: 0.28 * sin(2 * pi * (0.5 + (index % 7) * 0.11) * t),
          z: 0.18 * sin(2 * pi * (1.7 + (index % 5) * 0.16) * t),
        );
      });

      expect(analyzer.estimate(samples), isNull);
    });
  });

  group('estimateSpm (後方互換)', () {
    test('等間隔1軸波形も推定できる', () {
      const rate = 24.0;
      final samples = List<double>.generate(15 * 50, (index) {
        final t = index / 50;
        return sin(2 * pi * rate / 60 * t);
      });

      expect(analyzer.estimateSpm(samples, 50), closeTo(24, 1));
    });
  });
}
