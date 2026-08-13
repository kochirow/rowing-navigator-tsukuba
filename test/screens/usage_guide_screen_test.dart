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
}
