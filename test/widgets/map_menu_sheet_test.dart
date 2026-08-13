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

  testWidgets('塊が変わったところにだけ見出しを出す', (tester) async {
    // 出艇前は行き先が9つ前後になる。平らに並べると、性質の違う4種類が
    // 混ざっていた元の状態へ戻ってしまう。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapMenuSheet(
            actions: [
              // 先頭の表示切替は塊に入れず、見出し無しで置く。
              MapMenuAction(
                icon: Icons.layers_outlined,
                title: '表示',
                onTap: () {},
              ),
              MapMenuAction(
                icon: Icons.shield_outlined,
                title: '警告の設定',
                section: '準備',
                onTap: () {},
              ),
              MapMenuAction(
                icon: Icons.groups_outlined,
                title: 'チーム',
                section: '準備',
                onTap: () {},
              ),
              MapMenuAction(
                icon: Icons.timeline_outlined,
                title: '練習記録',
                section: '記録',
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );

    // 同じ塊の2項目めで見出しを繰り返さない。
    expect(find.text('準備'), findsOneWidget);
    expect(find.text('記録'), findsOneWidget);
    // 塊に属さない項目には見出しを出さない。
    expect(find.text('表示'), findsOneWidget);
    expect(find.byType(ListTile), findsNWidgets(4));
  });

  testWidgets('航行中のように塊が無ければ見出しを一切出さない', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapMenuSheet(
            actions: [
              MapMenuAction(
                icon: Icons.layers_outlined,
                title: '表示',
                onTap: () {},
              ),
              MapMenuAction(
                icon: Icons.add_location_alt_outlined,
                title: '危険区域を追加',
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );

    // 見出し用の Divider は1本も出ない(ListTile 自体は罫線を持たない)。
    expect(find.byType(Divider), findsNothing);
    expect(find.byType(ListTile), findsNWidgets(2));
  });
}
