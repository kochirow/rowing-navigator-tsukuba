import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/features/home_map/widgets/nav_status_card.dart';
import 'package:rowing_navigator/theme/app_theme.dart';

void main() {
  Future<void> pumpCard(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: NavStatusCard(
            paceSeconds: 120,
            distanceMeters: 1000,
            elapsedTimeSeconds: 60,
          ),
        ),
      ),
    );
  }

  testWidgets('計器下にはシステム状態の文字を表示しない', (tester) async {
    await pumpCard(tester);

    expect(find.textContaining('GPS'), findsNothing);
    expect(find.textContaining('安全設定'), findsNothing);
    expect(find.textContaining('共有'), findsNothing);
    expect(find.textContaining('周囲を目視確認'), findsNothing);
  });
}
