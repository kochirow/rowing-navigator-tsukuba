import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/widgets/app_state_views.dart';

void main() {
  testWidgets('ローディングと空状態は文脈固有の文言を表示する', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AppLoadingView(message: '読み込み中です…'),
        ),
      ),
    );
    expect(find.byIcon(Icons.rowing), findsOneWidget);
    expect(find.text('読み込み中です…'), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AppEmptyView(
            icon: Icons.history,
            title: '記録がありません',
            message: '航行後に表示されます',
          ),
        ),
      ),
    );
    expect(find.text('記録がありません'), findsOneWidget);
    expect(find.text('航行後に表示されます'), findsOneWidget);
  });

  testWidgets('エラー表示の主・副ボタンから既存処理を呼べる', (tester) async {
    var primaryCount = 0;
    var secondaryCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppErrorView(
            title: '開始できませんでした',
            message: '通信状態を確認してください。',
            primaryLabel: '再試行',
            onPrimary: () => primaryCount += 1,
            secondaryLabel: '端末の設定を開く',
            onSecondary: () => secondaryCount += 1,
          ),
        ),
      ),
    );

    await tester.tap(find.text('再試行'));
    await tester.tap(find.text('端末の設定を開く'));
    expect(primaryCount, 1);
    expect(secondaryCount, 1);
  });
}
