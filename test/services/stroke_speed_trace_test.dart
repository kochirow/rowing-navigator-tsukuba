import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/stroke_trace_config.dart';
import 'package:rowing_navigator/services/stroke_speed_trace.dart';

/// 50Hzで、周期[periodSeconds]の艇長軸加速度を流し込む。
/// 加速度は sin なので、その積分(艇速変動)は -cos になる。
void _feedSine(
  StrokeSpeedTraceRecorder recorder, {
  required DateTime start,
  required double seconds,
  required double periodSeconds,
  double amplitude = 1.0,
  double bias = 0.0,
}) {
  const hz = 50;
  final count = (seconds * hz).round();
  for (var index = 0; index <= count; index++) {
    final t = index / hz;
    recorder.addSample(
      timestamp: start.add(
        Duration(microseconds: (t * Duration.microsecondsPerSecond).round()),
      ),
      x: amplitude * math.sin(2 * math.pi * t / periodSeconds) + bias,
      y: 0,
      z: 0,
    );
  }
}

void main() {
  final start = DateTime.utc(2026, 8, 3, 6);

  group('StrokeSpeedTraceRecorder', () {
    test('艇長軸が確定するまでは1点も記録しない', () {
      final recorder = StrokeSpeedTraceRecorder();
      _feedSine(recorder, start: start, seconds: 5, periodSeconds: 2);
      expect(recorder.hasAxis, isFalse);
      expect(recorder.length, 0);
      expect(
        recorder.window(now: start.add(const Duration(seconds: 5)),
            windowSeconds: 6),
        isNull,
      );
    });

    test('50Hz入力を25Hz前後へ間引いて保持する', () {
      final recorder = StrokeSpeedTraceRecorder()
        ..setLongitudinalAxis(x: 1, y: 0, z: 0, bias: 0);
      _feedSine(recorder, start: start, seconds: 4, periodSeconds: 2);
      // 4秒 × 25Hz = 100点前後(端数と最初の1点ぶんの差を許容)。
      expect(recorder.length, greaterThan(90));
      expect(recorder.length, lessThan(110));
    });

    test('窓の平均艇速はGNSS艇速に一致する(加速度バイアスがあっても)', () {
      final recorder = StrokeSpeedTraceRecorder()
        ..setLongitudinalAxis(x: 1, y: 0, z: 0, bias: 0)
        ..setBaseSpeed(4.0);
      // bias 0.05 m/s^2 を混ぜる。ハイパスと窓平均の両方が効かないと、
      // 平均艇速がGNSSからずれて「速く漕げている」ように見えてしまう。
      _feedSine(
        recorder,
        start: start,
        seconds: 10,
        periodSeconds: 2,
        bias: 0.05,
      );
      final window = recorder.window(
        now: start.add(const Duration(seconds: 10)),
        windowSeconds: 4,
      );
      expect(window, isNotNull);
      expect(window!.meanSpeed, closeTo(4.0, 0.05));
    });

    test('正弦加速度から、位相が90度遅れた艇速変動を作る', () {
      final recorder = StrokeSpeedTraceRecorder()
        ..setLongitudinalAxis(x: 1, y: 0, z: 0, bias: 0)
        ..setBaseSpeed(4.0);
      _feedSine(recorder, start: start, seconds: 12, periodSeconds: 2);
      final window = recorder.window(
        now: start.add(const Duration(seconds: 12)),
        windowSeconds: 4,
      );
      expect(window, isNotNull);
      // 振幅1・角周波数π の積分なので、変動の振幅は 1/π ≒ 0.318 m/s。
      final amplitude = (window!.maxSpeed - window.minSpeed) / 2;
      expect(amplitude, closeTo(1 / math.pi, 0.06));
    });

    test('欠測をまたいで積分せず、再開後に立ち上げ直す', () {
      final recorder = StrokeSpeedTraceRecorder()
        ..setLongitudinalAxis(x: 1, y: 0, z: 0, bias: 0)
        ..setBaseSpeed(4.0);
      _feedSine(recorder, start: start, seconds: 4, periodSeconds: 2);
      final before = recorder.length;
      // 1秒の欠測(最大許容 0.25 秒を超える)。
      recorder.addSample(
        timestamp: start.add(const Duration(seconds: 5)),
        x: 1,
        y: 0,
        z: 0,
      );
      // 欠測直後のサンプルは積分にも記録にも使わない。
      expect(recorder.length, before);
    });

    test('キャッチ時刻は窓の内側だけを返す', () {
      final recorder = StrokeSpeedTraceRecorder()
        ..setLongitudinalAxis(x: 1, y: 0, z: 0, bias: 0)
        ..setBaseSpeed(4.0)
        ..noteStrokeBoundary(start.add(const Duration(seconds: 1)))
        ..noteStrokeBoundary(start.add(const Duration(seconds: 9)));
      _feedSine(recorder, start: start, seconds: 10, periodSeconds: 2);
      final window = recorder.window(
        now: start.add(const Duration(seconds: 10)),
        windowSeconds: 4,
      );
      expect(window, isNotNull);
      expect(window!.catchTimesMs, hasLength(1));
      expect(
        window.catchTimesMs.single,
        start.add(const Duration(seconds: 9)).millisecondsSinceEpoch,
      );
    });

    test('リングは設定秒数を超えて溜め込まない', () {
      final recorder = StrokeSpeedTraceRecorder()
        ..setLongitudinalAxis(x: 1, y: 0, z: 0, bias: 0);
      _feedSine(recorder, start: start, seconds: 60, periodSeconds: 2);
      expect(
        recorder.length,
        lessThanOrEqualTo(
          strokeTraceBufferSeconds * strokeTraceSampleHz + 8,
        ),
      );
    });
  });

  group('resampleStroke', () {
    test('区間がリングに収まっていなければ null を返す', () {
      final recorder = StrokeSpeedTraceRecorder()
        ..setLongitudinalAxis(x: 1, y: 0, z: 0, bias: 0);
      _feedSine(recorder, start: start, seconds: 4, periodSeconds: 2);
      expect(
        recorder.resampleStroke(
          start: start.subtract(const Duration(seconds: 5)),
          end: start.add(const Duration(seconds: 1)),
        ),
        isNull,
      );
    });

    test('指定点数へ再標本化し、平均を0にする', () {
      final recorder = StrokeSpeedTraceRecorder()
        ..setLongitudinalAxis(x: 1, y: 0, z: 0, bias: 0);
      _feedSine(recorder, start: start, seconds: 10, periodSeconds: 2);
      final waveform = recorder.resampleStroke(
        start: start.add(const Duration(seconds: 6)),
        end: start.add(const Duration(seconds: 8)),
        samples: 48,
      );
      expect(waveform, isNotNull);
      expect(waveform!, hasLength(48));
      final mean = waveform.reduce((a, b) => a + b) / waveform.length;
      expect(mean, closeTo(0, 1e-9));
      expect(waveform.every((value) => value.isFinite), isTrue);
    });
  });

  group('strokeTraceWindowSecondsFor', () {
    test('SPMから2ストロークぶんの窓を作る', () {
      expect(strokeTraceWindowSecondsFor(spm: 30), closeTo(4.0, 1e-9));
      expect(strokeTraceWindowSecondsFor(spm: 20), closeTo(6.0, 1e-9));
    });

    test('SPMが取れなくてもグラフを消さず、既定の窓へ縮退する', () {
      expect(
        strokeTraceWindowSecondsFor(spm: null),
        strokeTraceFallbackWindowSeconds,
      );
      expect(
        strokeTraceWindowSecondsFor(spm: 0),
        strokeTraceFallbackWindowSeconds,
      );
    });

    test('極端なSPMでも上下限に収める', () {
      expect(
        strokeTraceWindowSecondsFor(spm: 60),
        strokeTraceMinimumWindowSeconds,
      );
      expect(
        strokeTraceWindowSecondsFor(spm: 5),
        strokeTraceMaximumWindowSeconds,
      );
    });
  });
}
