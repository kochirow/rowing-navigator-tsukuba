import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/screens/first_run_guide_screen.dart';
import 'package:rowing_navigator/services/first_run_guide_store.dart';
import 'package:rowing_navigator/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 案内を開くボタンだけの画面。閉じたら元へ戻ることを確かめる。
Widget _launcher() => MaterialApp(
      theme: buildAppTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const FirstRunGuideScreen()),
              ),
              child: const Text('開く'),
            ),
          ),
        ),
      ),
    );

void main() {
  group('初回の自動表示', hookTests);

  testWidgets('どの画面からでもスキップで閉じられる', (tester) async {
    await tester.pumpWidget(_launcher());
    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();

    expect(find.textContaining('衝突回避を保証しません'), findsOneWidget);
    await tester.tap(find.text('次へ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('スキップ'));
    await tester.pumpAndSettle();

    expect(find.byType(FirstRunGuideScreen), findsNothing);
    expect(find.text('開く'), findsOneWidget);
  });

  testWidgets('選んだ役割の手順だけを見せ、最後に「はじめる」で閉じる', (tester) async {
    await tester.pumpWidget(_launcher());
    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('次へ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('監視する'));
    await tester.pumpAndSettle();

    expect(find.text('監視するとき'), findsOneWidget);
    expect(find.text('航行するとき'), findsNothing);
    expect(find.textContaining('「監視スタート」を押します'), findsOneWidget);

    await tester.tap(find.text('次へ'));
    await tester.pumpAndSettle();
    expect(find.text('はじめる'), findsOneWidget);
    expect(find.text('スキップ'), findsNothing);
    expect(find.text('他艇 の警告音'), findsOneWidget);

    await tester.tap(find.text('はじめる'));
    await tester.pumpAndSettle();
    expect(find.byType(FirstRunGuideScreen), findsNothing);
  });

  testWidgets('役割を選ばずに進んでも、両方の手順を見せる', (tester) async {
    // 選択は3枚目の中身を変えるだけで、進むための条件にしない。
    await tester.pumpWidget(_launcher());
    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('次へ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('次へ'));
    await tester.pumpAndSettle();

    expect(find.text('航行するとき'), findsOneWidget);
    expect(find.text('監視するとき'), findsOneWidget);
  });
}

Widget _hookHost({required bool ready}) => MaterialApp(
      theme: buildAppTheme(),
      home: HookBuilder(
        builder: (context) {
          useFirstRunGuide(
            context,
            ready: ready,
            primaryWarningLeadSeconds: 10,
            advanceWarningLeadSeconds: 13,
          );
          return const Scaffold(body: Text('地図'));
        },
      ),
    );

void hookTests() {
  testWidgets('待機中になるまで出さず、なったら1回だけ出す', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_hookHost(ready: false));
    await tester.pumpAndSettle();
    expect(find.byType(FirstRunGuideScreen), findsNothing);

    await tester.pumpWidget(_hookHost(ready: true));
    await tester.pumpAndSettle();
    expect(find.byType(FirstRunGuideScreen), findsOneWidget);

    await tester.tap(find.text('スキップ'));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(FirstRunGuideStore.seenKey), isTrue);
  });

  testWidgets('航行したことのある端末には出さない', (tester) async {
    SharedPreferences.setMockInitialValues({
      FirstRunGuideStore.existingUserKey: '後藤',
    });
    await tester.pumpWidget(_hookHost(ready: true));
    await tester.pumpAndSettle();
    expect(find.byType(FirstRunGuideScreen), findsNothing);
    expect(find.text('地図'), findsOneWidget);
  });
}
