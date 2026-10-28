import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/screens/about_app_screen.dart';
import 'package:rowing_navigator/widgets/startup_motto_view.dart';

void main() {
  testWidgets('起動画面に従来の読み込み表示と標語を出す', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: StartupMottoView(message: 'サービスを準備しています…')),
      ),
    );
    expect(find.text(clubMotto), findsOneWidget);
    expect(find.byIcon(Icons.rowing), findsOneWidget);
    expect(find.text('サービスを準備しています…'), findsOneWidget);
  });

  testWidgets('小さい端末でも標語がはみ出さない', (tester) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
          home: Scaffold(body: StartupMottoView(message: '確認中…'))),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('このアプリについてに趣旨を載せる', (tester) async {
    // 全文が一度に入る縦長の画面で、見出しがすべて描かれることを確かめる。
    tester.view.physicalSize = const Size(400, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: AboutAppScreen()));
    expect(find.text(AboutAppScreen.title), findsOneWidget);
    expect(find.text(clubMotto), findsOneWidget);
    for (final (heading, _) in AboutAppScreen.sections) {
      expect(find.text(heading), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('このアプリについての最後に版・クレジット・ライセンスがある', (tester) async {
    tester.view.physicalSize = const Size(400, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: AboutAppScreen()));
    await tester.pumpAndSettle();
    final info = find.byKey(const Key('about-app-info'));
    expect(info, findsOneWidget);
    for (final label in ['版', 'クレジット', 'オープンソースライセンス']) {
      expect(find.descendant(of: info, matching: find.text(label)),
          findsOneWidget);
    }
  });
}
