import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/features/home_map/widgets/nav_phase_chip.dart';
import 'package:rowing_navigator/theme/app_theme.dart';
import 'package:rowing_navigator/types/home_phase.dart';

void main() {
  Widget wrap(HomePhase phase) => MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: NavPhaseChip(phase: phase)),
      );

  testWidgets('3つの姿勢をすべて名指しする', (tester) async {
    // 以前は監視中だけ出しており、出艇前と航行中は同じ地図で
    // 見分けられなかった。
    for (final (phase, label) in const [
      (HomePhase.ashore, '出艇前'),
      (HomePhase.navigating, '航行中'),
      (HomePhase.watching, '監視中'),
    ]) {
      await tester.pumpWidget(wrap(phase));
      expect(find.text(label), findsOneWidget, reason: '$phase');
    }
  });

  testWidgets('出艇前だけタブを出す', (tester) async {
    expect(HomePhase.ashore.showsTabs, isTrue);
    expect(HomePhase.navigating.showsTabs, isFalse);
    expect(HomePhase.watching.showsTabs, isFalse);
  });
}
