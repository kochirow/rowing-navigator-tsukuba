import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/features/home_map/widgets/rounded_button.dart';
import 'package:rowing_navigator/theme/app_theme.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  Color labelColor(WidgetTester tester) =>
      tester.widget<Text>(find.text('航行スタート')).style!.color!;
  Color surfaceColor(WidgetTester tester) => tester
      .widget<Material>(find.descendant(
        of: find.byType(RoundedButton),
        matching: find.byType(Material),
      ))
      .color!;

  for (final (name, theme) in [
    ('明色', buildAppTheme()),
    ('暗色', buildAppDarkTheme()),
  ]) {
    testWidgets('$nameテーマの既定の面では文字が通常文字の基準(4.5:1)以上で読める',
        (tester) async {
      // 暗色テーマのプライマリは明るい水色。白文字を固定していた頃は約2.3:1だった。
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Scaffold(
          body: RoundedButton(label: '航行スタート', onPressed: () {}),
        ),
      ));
      expect(
        _contrast(labelColor(tester), surfaceColor(tester)),
        greaterThanOrEqualTo(4.5),
      );
    });
  }

  testWidgets('面の色を指定したときは従来どおり白文字を既定にする', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: RoundedButton(
          label: '航行スタート',
          color: const Color(0xFF002E4D),
          onPressed: () {},
        ),
      ),
    ));
    expect(labelColor(tester), Colors.white);
  });
}
