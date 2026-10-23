import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/screens/warning_settings_widgets.dart';
import 'package:rowing_navigator/theme/app_theme.dart';

void main() {
  // iPhone 17 Pro の幅(402pt)。2026-10-23、この幅で「10.0秒前」の
  // 「秒前」だけが次の行へ落ちていた。
  Future<void> pumpStepper(WidgetTester tester, double textScale) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(402, 874),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: ValueStepper(
              label: '不確かなとき',
              caption: '8.5秒以上',
              value: '10.0秒前',
              changed: false,
              keyPrefix: 'lead-primary',
              onDecrement: () {},
              onIncrement: () {},
            ),
          ),
        ),
      ),
    ));
  }

  // 1行なら高さは文字の大きさの約1.2倍、2行なら約2.4倍になる。
  double valueHeightInFontSizes(WidgetTester tester, double scale) {
    final paragraph = tester.renderObject<RenderParagraph>(find.descendant(
      of: find.byKey(const ValueKey('lead-primary-value')),
      matching: find.byType(RichText),
    ));
    return paragraph.size.height / (20 * scale);
  }

  for (final scale in [1.0, 1.3]) {
    testWidgets('値は折り返さず1行に収める(文字の拡大 $scale)', (tester) async {
      await pumpStepper(tester, scale);
      expect(find.text('10.0秒前'), findsOneWidget);
      expect(valueHeightInFontSizes(tester, scale), lessThan(1.8));
    });
  }
}
