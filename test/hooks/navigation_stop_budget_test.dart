import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/hooks/navigation_stop_budget.dart';

void main() {
  group('NavigationStopBudget', () {
    const budget = NavigationStopBudget(
      totalBudget: Duration(seconds: 15),
      defaultStepTimeout: Duration(seconds: 5),
    );

    test('各工程は既定上限と残り時間の小さい方だけ待つ', () {
      expect(budget.timeoutFor(Duration.zero), const Duration(seconds: 5));
      expect(
        budget.timeoutFor(const Duration(seconds: 12)),
        const Duration(seconds: 3),
      );
    });

    test('予算を使い切った工程は待たずに飛ばす', () {
      expect(budget.timeoutFor(const Duration(seconds: 15)), isNull);
      expect(budget.timeoutFor(const Duration(seconds: 16)), isNull);
    });

    test('開始チェックポイントは工程既定より長く待たない', () {
      expect(
        budget.timeoutFor(
          const Duration(seconds: 13),
          preferredTimeout: const Duration(seconds: 5),
        ),
        const Duration(seconds: 2),
      );
    });
  });

  test('終了世代が変わった古い工程は状態を書き換えない', () {
    expect(isCurrentStopGeneration(expected: 3, current: 3), isTrue);
    expect(isCurrentStopGeneration(expected: 3, current: 4), isFalse);
  });
}
