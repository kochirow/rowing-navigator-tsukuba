import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/features/home_map/widgets/background_location_disclosure_dialog.dart';

void main() {
  testWidgets('バックグラウンド位置情報の取得・共有・停止条件を説明する', (tester) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<bool>(
                  context: context,
                  builder: (_) => const BackgroundLocationDisclosureDialog(),
                );
              },
              child: const Text('開く'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();

    expect(find.text(BackgroundLocationDisclosureDialog.title), findsOneWidget);
    expect(find.textContaining('アプリを使用していないとき'), findsOneWidget);
    expect(find.textContaining('画面消灯中や別アプリ表示中'), findsOneWidget);
    expect(find.textContaining('Firebaseへ一時送信'), findsOneWidget);
    expect(find.textContaining('航行を終了すると'), findsOneWidget);
    expect(find.text('キャンセル'), findsOneWidget);
    expect(find.text('同意して続ける'), findsOneWidget);

    await tester.tap(find.text('同意して続ける'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });
}
