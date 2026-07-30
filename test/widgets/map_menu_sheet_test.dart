import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/features/home_map/widgets/map_menu_sheet.dart';

void main() {
  testWidgets('メニュー項目はシートを閉じてから既存処理を呼ぶ', (tester) async {
    var tapCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (_) => MapMenuSheet(
                  actions: [
                    MapMenuAction(
                      icon: Icons.shield_outlined,
                      title: '安全設定',
                      subtitle: '危険区域の幅・警告開始時間・プライバシー',
                      onTap: () => tapCount += 1,
                    ),
                  ],
                ),
              ),
              child: const Text('開く'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();
    expect(find.text('安全設定'), findsOneWidget);
    expect(find.text('危険区域の幅・警告開始時間・プライバシー'), findsOneWidget);

    await tester.tap(find.text('安全設定'));
    await tester.pumpAndSettle();
    expect(tapCount, 1);
    expect(find.text('安全設定'), findsNothing);
  });

  testWidgets('航行中に使えない項目は消さず、理由を添えて無効表示にする', (tester) async {
    var tapCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (_) => MapMenuSheet(
                  actions: [
                    MapMenuAction(
                      icon: Icons.history,
                      title: '記録',
                      subtitle: '過去の練習ログ',
                      enabled: false,
                      disabledReason: '航行終了後に利用できます',
                      onTap: () => tapCount += 1,
                    ),
                  ],
                ),
              ),
              child: const Text('開く'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();

    // 項目は残る。位置が変わらないことがここでの要点。
    expect(find.text('記録'), findsOneWidget);
    expect(find.text('航行終了後に利用できます'), findsOneWidget);
    expect(find.text('過去の練習ログ'), findsNothing);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);

    // 押しても処理は動かず、シートも閉じない。
    await tester.tap(find.text('記録'));
    await tester.pumpAndSettle();
    expect(tapCount, 0);
    expect(find.text('記録'), findsOneWidget);
  });
}
