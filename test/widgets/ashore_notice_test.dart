import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/features/home_map/widgets/ashore_notice.dart';
import 'package:rowing_navigator/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: child),
      );

  testWidgets('音を止めている事実と、止まっていないものを明示する', (tester) async {
    await tester.pumpWidget(wrap(AshoreNotice(onRestoreAudio: () {})));

    // 黙って音を止めると「鳴らないアプリ」と区別が付かない。
    expect(find.text('陸上と判定して警告音を止めています'), findsOneWidget);
    expect(
      find.textContaining('衝突判定・画面表示・記録は続いています'),
      findsOneWidget,
    );
    expect(find.textContaining('川へ戻れば自動で鳴ります'), findsOneWidget);
  });

  testWidgets('「音を戻す」で手動解除できる(原則2)', (tester) async {
    var restored = 0;
    await tester.pumpWidget(
      wrap(AshoreNotice(onRestoreAudio: () => restored++)),
    );

    await tester.tap(find.text('音を戻す'));
    await tester.pump();

    expect(restored, 1);
  });

  testWidgets('操作部は濡れた手でも押せる大きさを確保する', (tester) async {
    await tester.pumpWidget(wrap(AshoreNotice(onRestoreAudio: () {})));

    final button = tester.getSize(find.byType(TextButton));
    expect(button.height, greaterThanOrEqualTo(44));
    expect(button.width, greaterThanOrEqualTo(44));
  });
}
