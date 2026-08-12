import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/safety_evaluation_liveness.dart';

void main() {
  SafetyEvaluationLiveness monitor() => SafetyEvaluationLiveness(
        timerStallThreshold: const Duration(seconds: 3),
        evaluationStallThreshold: const Duration(seconds: 3),
      );

  test('GPS入力が止まっただけでは安全評価停止を報告しない', () {
    final liveness = monitor()
      ..recordSafetyInput(Duration.zero)
      ..recordSafetyEvaluationCompleted(Duration.zero)
      ..tick(Duration.zero);

    liveness.tick(const Duration(seconds: 1));
    liveness.tick(const Duration(seconds: 2));
    liveness.tick(const Duration(seconds: 3));
    final tick = liveness.tick(const Duration(seconds: 4));

    // タイマーは通常どおり1秒ごとに進んでいる。GPSの空白は
    // GpsHealthMonitor / position_processing_gap の責務であり、ここで
    // safety_evaluation_stalled へ誤分類しない。
    expect(tick.timerStalled, isFalse);
    expect(tick.evaluationStalled, isFalse);
  });

  test('GPSは届くが評価完了が古いと安全評価停止になる', () {
    final liveness = monitor()
      ..recordSafetyEvaluationCompleted(Duration.zero)
      ..tick(Duration.zero);

    liveness.tick(const Duration(seconds: 1));
    liveness.tick(const Duration(seconds: 2));
    liveness.tick(const Duration(seconds: 3));
    liveness.recordSafetyInput(const Duration(seconds: 4));

    final tick = liveness.tick(const Duration(seconds: 4));

    expect(tick.timerStalled, isFalse);
    expect(tick.evaluationStalled, isTrue);
    expect(tick.lastSafetyEvaluationAge, const Duration(seconds: 4));
  });

  test('評価が正常完了すれば安全評価停止から直ちに復帰する', () {
    final liveness = monitor()
      ..recordSafetyEvaluationCompleted(Duration.zero)
      ..tick(Duration.zero);

    liveness.tick(const Duration(seconds: 1));
    liveness.tick(const Duration(seconds: 2));
    liveness.tick(const Duration(seconds: 3));
    liveness.recordSafetyInput(const Duration(seconds: 4));

    expect(
      liveness.tick(const Duration(seconds: 4)).evaluationStalled,
      isTrue,
    );

    liveness.recordSafetyEvaluationCompleted(const Duration(seconds: 4));
    expect(
      liveness.tick(const Duration(seconds: 5)).evaluationStalled,
      isFalse,
    );
  });

  test('1秒タイマー自身の空白を独立して検出する', () {
    final liveness = monitor()..tick(Duration.zero);

    final tick = liveness.tick(const Duration(seconds: 4));

    expect(tick.timerStalled, isTrue);
    expect(tick.timerGap, const Duration(seconds: 4));
    expect(tick.evaluationStalled, isFalse);
  });

  group('測位間隔に追随する評価停止の閾値 (S3-17)', () {
    test('測位が密なら固定下限のままで、検出が甘くならない', () {
      final liveness = monitor();
      // 1秒間隔の測位を10回。実効間隔は1秒に収束する。
      for (var i = 0; i < 10; i++) {
        liveness.recordSafetyInput(Duration(seconds: i));
      }
      expect(
        liveness.effectiveEvaluationStallThreshold,
        const Duration(seconds: 3),
      );
    });

    test('測位が疎なら閾値が追随して広がる', () {
      final liveness = monitor();
      // 2026-08-06 実機の 2x と同じ 3 秒間隔。
      for (var i = 0; i < 10; i++) {
        liveness.recordSafetyInput(Duration(seconds: i * 3));
      }
      expect(
        liveness.effectiveEvaluationStallThreshold,
        greaterThan(const Duration(seconds: 3)),
      );
    });

    test('実機で fault が立った条件(間隔3秒・評価齢3.1秒)で立たない', () {
      // 実測値: lastSafetyEvaluationAgeMs が 3002/3012/3015/3190ms で
      // 6回 fault が立った。閾値と測位間隔が重なっていたのが原因。
      final liveness = monitor();
      for (var i = 0; i < 10; i++) {
        liveness.recordSafetyInput(Duration(seconds: i * 3));
        liveness.recordSafetyEvaluationCompleted(Duration(seconds: i * 3));
      }
      final now =
          const Duration(seconds: 27) + const Duration(milliseconds: 100);
      liveness.recordSafetyInput(now);
      final tick = liveness.tick(now);
      expect(tick.evaluationStalled, isFalse);
    });

    test('本当に評価が止まれば、疎な測位でも検出する', () {
      final liveness = monitor();
      for (var i = 0; i < 10; i++) {
        liveness.recordSafetyInput(Duration(seconds: i * 3));
      }
      // 評価は一度も完了していない。入力だけ新しい。
      liveness.recordSafetyInput(const Duration(seconds: 30));
      expect(
        liveness.tick(const Duration(seconds: 30)).evaluationStalled,
        isTrue,
      );
    });

    test('長い欠測は実効間隔へ取り込まない(GPS途絶は別の担当)', () {
      final liveness = monitor();
      for (var i = 0; i < 10; i++) {
        liveness.recordSafetyInput(Duration(seconds: i));
      }
      final before = liveness.effectiveEvaluationStallThreshold;
      // 橋の下で30秒欠測。ここで閾値が跳ね上がってはいけない。
      liveness.recordSafetyInput(const Duration(seconds: 40));
      expect(liveness.effectiveEvaluationStallThreshold, before);
    });
  });
}
