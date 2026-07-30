import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/features/home_map/widgets/safety_banner.dart';
import 'package:rowing_navigator/models/navigation_warning.dart';
import 'package:rowing_navigator/theme/app_theme.dart';

void main() {
  NavigationWarning otherBoat(
    WarningDisplayUrgency urgency, {
    int secondsUntilDanger = 6,
  }) =>
      NavigationWarning(
        key: 'other_boat-boat-1',
        category: 'other_boat',
        title: '他艇に注意',
        message: '接近しています',
        audioAsset: null,
        timeUntilDanger: Duration(seconds: secondsUntilDanger),
        relativeBearingDegrees: 45,
        urgency: urgency,
      );

  // 注意: `imminent` の警告は白い縁が無限に脈動するため、`pumpAndSettle` は
  // 完了しない(safety_banner.dart のコメント参照)。必ず `pump(duration)` を使う。
  Future<void> showWarning(
    WidgetTester tester,
    WarningDisplayUrgency urgency,
  ) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: SafetyBanner(warnings: [otherBoat(urgency)])),
    ));
    await tester.pump(const Duration(milliseconds: 120));
  }

  testWidgets('imminent → action → imminent を往復しても例外が出ない', (tester) async {
    // バンドは到達時間だけで決まり、境界は7秒。相対速度が揺れる他艇は
    // この境界を何度も跨ぐ。脈動用の Ticker を作り直すと2本目が assert で
    // 拒否され、警告チップが ErrorWidget へ置き換わって「他艇」が消えていた。
    await showWarning(tester, WarningDisplayUrgency.imminent);
    expect(tester.takeException(), isNull);

    await showWarning(tester, WarningDisplayUrgency.action);
    expect(tester.takeException(), isNull);

    await showWarning(tester, WarningDisplayUrgency.imminent);
    expect(tester.takeException(), isNull);

    // 何度往復しても壊れないこと。
    for (var i = 0; i < 3; i++) {
      await showWarning(tester, WarningDisplayUrgency.action);
      await showWarning(tester, WarningDisplayUrgency.imminent);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('往復しても警告のラベルが描画され続ける', (tester) async {
    await showWarning(tester, WarningDisplayUrgency.imminent);
    expect(find.text('他艇'), findsAtLeastNWidgets(1));
    expect(find.byType(ErrorWidget), findsNothing);

    await showWarning(tester, WarningDisplayUrgency.action);
    expect(find.text('他艇'), findsAtLeastNWidgets(1));
    expect(find.byType(ErrorWidget), findsNothing);

    await showWarning(tester, WarningDisplayUrgency.imminent);
    expect(find.text('他艇'), findsAtLeastNWidgets(1));
    expect(find.byType(ErrorWidget), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('monitoring だけになれば脈動は止まる', (tester) async {
    await showWarning(tester, WarningDisplayUrgency.imminent);
    await showWarning(tester, WarningDisplayUrgency.monitoring);

    // 脈動が止まっていればフレームの予約が残らない。
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(find.text('他艇'), findsAtLeastNWidgets(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('警告が無ければ何も出さない', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: const Scaffold(body: SafetyBanner()),
    ));

    expect(find.text('他艇'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
