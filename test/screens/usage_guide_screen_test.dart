import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/screens/usage_guide_screen.dart';
import 'package:rowing_navigator/theme/app_theme.dart';

void main() {
  testWidgets('橋脚は外周を直接囲む方式として案内する', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: const UsageGuideScreen(),
      ),
    );

    await tester.scrollUntilVisible(
      find.text('橋脚の登録'),
      400,
      scrollable: find.byType(Scrollable),
    );
    expect(find.text('橋脚の登録'), findsOneWidget);
    expect(
      find.textContaining('実際の外周を3点以上で直接囲みます'),
      findsOneWidget,
    );
    expect(find.textContaining('幅[m]'), findsNothing);
  });

  testWidgets('警告の段階の秒数は、実際に効いている設定値で説明する', (tester) async {
    // 以前は「約7秒」「約10秒」と直書きで、既定の10秒・13秒と食い違っていた。
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: const UsageGuideScreen(),
      ),
    );
    expect(find.textContaining('あと10秒以内に届きます'), findsOneWidget);
    expect(find.textContaining('あと10〜13秒で届きます'), findsOneWidget);
    expect(find.text('断続音（3秒ごと）'), findsOneWidget);
    expect(find.textContaining('約7秒'), findsNothing);

    // 設定画面やチーム共有で変えた値は、そのまま説明に出る。
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: const UsageGuideScreen(
          primaryWarningLeadSeconds: 8.5,
          advanceWarningLeadSeconds: 15,
        ),
      ),
    );
    expect(find.textContaining('あと8.5秒以内に届きます'), findsOneWidget);
    expect(find.textContaining('あと8.5〜15秒で届きます'), findsOneWidget);
  });
}
