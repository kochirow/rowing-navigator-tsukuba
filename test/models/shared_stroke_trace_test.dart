import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/stroke_trace_config.dart';
import 'package:rowing_navigator/models/shared_stroke_trace.dart';
import 'package:rowing_navigator/services/firebase_usage_budget.dart';

List<double> _waveform({int samples = sharedStrokeWaveformSamples}) =>
    List<double>.generate(
      samples,
      (index) => 0.35 * math.sin(2 * math.pi * index / samples),
      growable: false,
    );

SharedStrokeTrace _trace({DateTime? startedAt}) => SharedStrokeTrace(
      strokeStartedAt: startedAt ?? DateTime.utc(2026, 8, 3, 6),
      strokeDuration: const Duration(milliseconds: 2400),
      baseSpeedMetersPerSecond: 4.2,
      relativeSpeeds: _waveform(),
      spm: 25,
      confidence: 0.81,
      distancePerStrokeMeters: 10.1,
      catchSpeedLossMetersPerSecond: 0.42,
      lateDriveSpeedGainMetersPerSecond: -0.13,
      recoverySpeedRetention: 0.76,
      finishPhaseFraction: 0.38,
    );

void main() {
  group('StrokeWaveformCodec', () {
    test('往復して量子化誤差 1cm/s 以内に収まる', () {
      final original = _waveform();
      final decoded = StrokeWaveformCodec.decode(
        StrokeWaveformCodec.encode(original),
      );
      expect(decoded, isNotNull);
      expect(decoded!, hasLength(original.length));
      for (var index = 0; index < original.length; index++) {
        expect(decoded[index], closeTo(original[index], 0.005));
      }
    });

    test('48点の波形は64文字に収まる', () {
      expect(StrokeWaveformCodec.encode(_waveform()).length, 64);
    });

    test('±1.27m/sを超える値は飽和させ、壊さない', () {
      final decoded = StrokeWaveformCodec.decode(
        StrokeWaveformCodec.encode(List<double>.filled(16, 9.9)),
      );
      expect(decoded, isNotNull);
      expect(decoded!.every((value) => value == 1.27), isTrue);
    });

    test('非有限値は0として運ぶ(送信を止めない)', () {
      final decoded = StrokeWaveformCodec.decode(
        StrokeWaveformCodec.encode(
            [double.nan, double.infinity, ...List<double>.filled(10, 0.1)]),
      );
      expect(decoded, isNotNull);
      expect(decoded![0], 0);
      expect(decoded[1], 0);
    });

    test('短すぎる・長すぎる・壊れた文字列は拒否する', () {
      expect(StrokeWaveformCodec.decode(''), isNull);
      expect(StrokeWaveformCodec.decode('AAAA'), isNull); // 3バイト
      expect(StrokeWaveformCodec.decode('!!!!not-base64!!!!'), isNull);
      expect(
        StrokeWaveformCodec.decode(
          StrokeWaveformCodec.encode(List<double>.filled(200, 0.1)),
        ),
        isNull,
      );
    });
  });

  group('SharedStrokeTrace', () {
    test('RTDB往復で指標が保たれる', () {
      final original = _trace();
      final restored = SharedStrokeTrace.fromRtdbJson(
        original.toRtdbJson().cast<Object?, Object?>(),
      );
      expect(restored, isNotNull);
      expect(
        restored!.strokeStartedAt.toUtc(),
        original.strokeStartedAt.toUtc(),
      );
      expect(restored.strokeDuration, original.strokeDuration);
      expect(restored.baseSpeedMetersPerSecond, closeTo(4.2, 0.005));
      expect(restored.spm, closeTo(25, 0.05));
      expect(restored.distancePerStrokeMeters, closeTo(10.1, 0.005));
      expect(restored.catchSpeedLossMetersPerSecond, closeTo(0.42, 0.005));
      // 終盤失速(負値)を符号ごと保つ。0へ潰すと失速が見えなくなる。
      expect(
        restored.lateDriveSpeedGainMetersPerSecond,
        closeTo(-0.13, 0.005),
      );
      expect(restored.recoverySpeedRetention, closeTo(0.76, 0.005));
      expect(restored.finishPhaseFraction, closeTo(0.38, 0.001));
      expect(restored.relativeSpeeds, hasLength(sharedStrokeWaveformSamples));
    });

    test('1件のpayloadは見積り上限に収まる', () {
      final json = _trace().toRtdbJson(serverUpdatedAt: 1780000000000);
      final bytes = json.entries.fold<int>(
        2,
        (total, entry) =>
            total + entry.key.length + 4 + '${entry.value}'.length,
      );
      expect(bytes, lessThanOrEqualTo(FirebaseUsageBudget.maxStrokeTraceBytes));
    });

    test('現実にありえない周期・艇速は受け取らない', () {
      final json = _trace().toRtdbJson().cast<Object?, Object?>();
      expect(
        SharedStrokeTrace.fromRtdbJson({...json, 'd': 120}),
        isNull,
      );
      expect(
        SharedStrokeTrace.fromRtdbJson({...json, 'd': 9000}),
        isNull,
      );
      expect(
        SharedStrokeTrace.fromRtdbJson({...json, 'b': -1}),
        isNull,
      );
    });

    test('必須フィールドが欠けた1件で監視表示を止めず、nullを返す', () {
      final json = _trace().toRtdbJson().cast<Object?, Object?>();
      for (final key in ['o', 'd', 'b', 'w']) {
        final broken = {...json}..remove(key);
        expect(SharedStrokeTrace.fromRtdbJson(broken), isNull, reason: key);
      }
      expect(
        SharedStrokeTrace.fromRtdbJson({...json, 'w': 12}),
        isNull,
      );
    });

    test('推定フィニッシュ時刻はストローク区間の内側に入る', () {
      final trace = _trace();
      expect(trace.finishAt.isAfter(trace.strokeStartedAt), isTrue);
      expect(trace.finishAt.isBefore(trace.strokeEndedAt), isTrue);
    });

    test('絶対艇速は負にならない', () {
      final trace = SharedStrokeTrace(
        strokeStartedAt: DateTime.utc(2026, 8, 3, 6),
        strokeDuration: const Duration(milliseconds: 2400),
        baseSpeedMetersPerSecond: 0.1,
        relativeSpeeds: const [-0.9, 0.9, -0.9, 0.9],
        spm: 25,
        confidence: 0.5,
        distancePerStrokeMeters: 0.24,
        catchSpeedLossMetersPerSecond: 0.9,
        lateDriveSpeedGainMetersPerSecond: 0.1,
        recoverySpeedRetention: 0.5,
        finishPhaseFraction: 0.4,
      );
      expect(trace.absoluteSpeeds.every((value) => value >= 0), isTrue);
    });
  });
}
