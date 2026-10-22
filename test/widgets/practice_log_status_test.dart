import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/features/home_map/widgets/practice_log_status.dart';
import 'package:rowing_navigator/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: child),
      );

  testWidgets('保存できないことを黙らせず、短い語と読み上げの全文で示す', (tester) async {
    await tester.pumpWidget(wrap(const PracticeLogFailureNotice(
      message: '練習ログを端末へ保存できませんでした。監視は継続しています。',
    )));

    expect(find.text('記録できません'), findsOneWidget);
    expect(
      find.bySemanticsLabel('練習ログを端末へ保存できませんでした。監視は継続しています。'),
      findsOneWidget,
    );
  });

  testWidgets('記録中だけ赤い点を重ねる', (tester) async {
    await tester.pumpWidget(
        wrap(const RecordingDot(recording: true, child: Text('監視終了'))));
    expect(find.byKey(const ValueKey('watch-recording-dot')), findsOneWidget);

    await tester.pumpWidget(
        wrap(const RecordingDot(recording: false, child: Text('監視終了'))));
    expect(find.byKey(const ValueKey('watch-recording-dot')), findsNothing);
  });
}
