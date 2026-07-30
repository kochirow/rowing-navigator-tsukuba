import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/screens/fixed_obstacle_warning_settings_screen.dart';
import 'package:rowing_navigator/services/fixed_obstacle_warning_settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('島2（上流）は初期状態でオフ、設定画面からオンへ変更できる', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: FixedObstacleWarningSettingsScreen()),
    );
    await tester.pumpAndSettle();

    final islandSwitch = tester.widget<Switch>(
      find.descendant(
        of: find.widgetWithText(SwitchListTile, '島2（上流）'),
        matching: find.byType(Switch),
      ),
    );
    expect(islandSwitch.value, isFalse);

    await tester.tap(find.widgetWithText(SwitchListTile, '島2（上流）'));
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(
      (await FixedObstacleWarningSettingsService().load())
          .isEnabled('island_upstream'),
      isTrue,
    );
  });
}
