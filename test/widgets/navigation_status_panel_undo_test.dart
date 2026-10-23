import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/features/home_map/widgets/navigation_status_panel.dart';
import 'package:rowing_navigator/theme/app_theme.dart';

void main() {
  testWidgets('RESET の「元に戻す」付き通知は、触らなくても約5秒で消える', (tester) async {
    final startedAt = DateTime(2026, 10, 23, 9);
    var undos = 0;
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: NavigationStatusPanel(
          paceSeconds: 120,
          distanceMeters: 500,
          sessionStartedAt: startedAt,
          portraitCompact: true,
          clock: () => startedAt,
          onLowerReset: () {},
          onLowerUndo: () => undos++,
        ),
      ),
    ));

    await tester.tap(find.text('RESET'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('下の計器を0にしました'), findsOneWidget);
    expect(find.text('元に戻す'), findsOneWidget);

    // 漕手は航行中に画面を触れないので、押さなくても閉じること。
    await tester.pump(undoSnackBarDuration);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('下の計器を0にしました'), findsNothing);
    expect(undos, 0);
  });
}
