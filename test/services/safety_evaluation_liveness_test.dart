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
}
