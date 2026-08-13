import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/stroke_trace_config.dart';
import 'package:rowing_navigator/models/shared_stroke_trace.dart';
import 'package:rowing_navigator/services/stroke_trace_history.dart';
import 'package:rowing_navigator/services/stroke_trace_share_service.dart';

SharedStrokeTrace _trace({
  required DateTime startedAt,
  Duration duration = const Duration(milliseconds: 2400),
  double baseSpeed = 4.2,
}) =>
    SharedStrokeTrace(
      strokeStartedAt: startedAt,
      strokeDuration: duration,
      baseSpeedMetersPerSecond: baseSpeed,
      relativeSpeeds: List<double>.generate(
        sharedStrokeWaveformSamples,
        (index) =>
            0.35 * math.sin(2 * math.pi * index / sharedStrokeWaveformSamples),
        growable: false,
      ),
      spm: 25,
      confidence: 0.8,
      distancePerStrokeMeters: 10.1,
      catchSpeedLossMetersPerSecond: 0.4,
      lateDriveSpeedGainMetersPerSecond: 0.1,
      recoverySpeedRetention: 0.75,
      finishPhaseFraction: 0.4,
    );

void main() {
  final t0 = DateTime.utc(2026, 8, 3, 6);

  group('StrokeTraceHistory', () {
    test('受信が無ければ窓を作らない(空白を捏造しない)', () {
      final history = StrokeTraceHistory();
      expect(history.window(now: t0), isNull);
      expect(history.isStale(t0), isTrue);
      expect(history.ageSince(t0), isNull);
    });

    test('連続する2ストロークを1本の波形へつなぐ', () {
      final history = StrokeTraceHistory()
        ..add(_trace(startedAt: t0),
            receivedAt: t0.add(const Duration(seconds: 3)))
        ..add(
          _trace(startedAt: t0.add(const Duration(milliseconds: 2400))),
          receivedAt: t0.add(const Duration(milliseconds: 5400)),
        );
      final window = history.window(
        now: t0.add(const Duration(milliseconds: 5400)),
      );
      expect(window, isNotNull);
      // 2ストローク = 4.8秒ぶんの窓に、両ストロークの点が入る。
      expect(window!.length, greaterThan(sharedStrokeWaveformSamples));
      expect(window.catchTimesMs, hasLength(2));
      // 時刻は必ず単調増加(境界の重複点を落としている)。
      for (var index = 1; index < window.length; index++) {
        expect(window.timesMs[index], greaterThan(window.timesMs[index - 1]));
      }
    });

    test('同じストロークの再送で点が二重にならない', () {
      final trace = _trace(startedAt: t0);
      final history = StrokeTraceHistory()
        ..add(trace, receivedAt: t0.add(const Duration(seconds: 3)))
        ..add(trace, receivedAt: t0.add(const Duration(seconds: 4)));
      final window = history.window(now: t0.add(const Duration(seconds: 4)));
      expect(window, isNotNull);
      expect(window!.catchTimesMs, hasLength(1));
    });

    test('受信からの経過で時間軸が進む(端末の時計ずれに依らない)', () {
      final history = StrokeTraceHistory()
        ..add(_trace(startedAt: t0),
            receivedAt: t0.add(const Duration(seconds: 3)));
      final early = history.window(now: t0.add(const Duration(seconds: 3)))!;
      final later = history.window(now: t0.add(const Duration(seconds: 5)))!;
      expect(later.endMs - early.endMs, closeTo(2000, 1));
      // 右端が進んだぶんだけ、実データとの間に空白ができる。埋めない。
      expect(later.trailingGapSeconds, greaterThan(early.trailingGapSeconds));
    });

    test('鮮度切れは途絶として扱う', () {
      final history = StrokeTraceHistory()
        ..add(_trace(startedAt: t0), receivedAt: t0);
      expect(history.isStale(t0.add(const Duration(seconds: 5))), isFalse);
      expect(
        history.isStale(t0.add(
          const Duration(seconds: sharedStrokeTraceFreshnessSeconds + 1),
        )),
        isTrue,
      );
    });

    test('保持するのは直近数ストロークだけ', () {
      final history = StrokeTraceHistory();
      for (var index = 0; index < 10; index++) {
        history.add(
          _trace(startedAt: t0.add(Duration(milliseconds: 2400 * index))),
          receivedAt: t0.add(Duration(milliseconds: 2400 * index + 100)),
        );
      }
      // 直近のストロークが残っている(古いものは捨てられている)。
      expect(
        history.latest!.strokeStartedAt,
        t0.add(const Duration(milliseconds: 2400 * 9)),
      );
    });

    test('表示窓は最新ストロークの2周期', () {
      final history = StrokeTraceHistory()
        ..add(
          _trace(startedAt: t0, duration: const Duration(milliseconds: 2000)),
          receivedAt: t0,
        );
      expect(history.windowSeconds(), closeTo(4.0, 1e-9));
    });
  });

  group('StrokeTracePublishPolicy', () {
    test('同じストロークを二度送らない', () {
      final policy = StrokeTracePublishPolicy();
      expect(policy.shouldPublish(strokeStartedAt: t0, now: t0), isTrue);
      policy.markPublished(strokeStartedAt: t0, now: t0);
      expect(
        policy.shouldPublish(
          strokeStartedAt: t0,
          now: t0.add(const Duration(seconds: 10)),
        ),
        isFalse,
      );
    });

    test('規則の下限を下回る連投を、規則に届く前に落とす', () {
      final policy = StrokeTracePublishPolicy();
      policy.markPublished(strokeStartedAt: t0, now: t0);
      expect(
        policy.shouldPublish(
          strokeStartedAt: t0.add(const Duration(milliseconds: 900)),
          now: t0.add(const Duration(milliseconds: 900)),
        ),
        isFalse,
      );
      expect(
        policy.shouldPublish(
          strokeStartedAt: t0.add(const Duration(milliseconds: 1900)),
          now: t0.add(const Duration(milliseconds: 1900)),
        ),
        isTrue,
      );
    });

    test('クライアント下限はRTDB規則の下限(1700ms)より大きい', () {
      expect(sharedStrokeTraceMinimumIntervalMs, greaterThan(1700));
    });
  });
}
