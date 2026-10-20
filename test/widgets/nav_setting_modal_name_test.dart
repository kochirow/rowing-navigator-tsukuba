import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rowing_navigator/features/home_map/widgets/nav_setting_modal.dart';
import 'package:rowing_navigator/services/account_display_name_service.dart';
import 'package:rowing_navigator/theme/app_theme.dart';
import 'package:rowing_navigator/types/boat_type.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<List<String>> pump(WidgetTester tester) async {
    final started = <String>[];
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: NavSettingModal(
              onPressStartNav: (name, _, __) async => started.add(name),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return started;
  }

  TextField nameField(WidgetTester tester) => tester.widget<TextField>(
        find.widgetWithText(TextField, '名前'),
      );

  testWidgets('名前欄にはアカウントの名前が入っている', (tester) async {
    SharedPreferences.setMockInitialValues({
      AccountDisplayNameService.displayNameKey: '後藤',
    });
    await pump(tester);
    expect(nameField(tester).controller!.text, '後藤');
  });

  testWidgets('前回この航行だけ変えた名前は持ち越さず、アカウントの名前に戻す', (tester) async {
    SharedPreferences.setMockInitialValues({
      AccountDisplayNameService.displayNameKey: '後藤',
      // 前回の航行で書き換えた名前。
      'navigation_display_name_v1': '代漕',
      'navigation_boat_type_v1': BoatType.r_4p.name,
      'navigation_seat_position_v1': 1,
    });
    await pump(tester);

    expect(nameField(tester).controller!.text, '後藤');
    // 前回の艇種・シート(4+ の cox)は復元する。
    expect(find.text('後藤・4+・cox'), findsOneWidget);
  });

  testWidgets('この航行だけ名前を書き換えて始められる', (tester) async {
    SharedPreferences.setMockInitialValues({
      AccountDisplayNameService.displayNameKey: '後藤',
    });
    final started = await pump(tester);

    await tester.enterText(find.widgetWithText(TextField, '名前'), '代漕');
    await tester.ensureVisible(find.text('航行スタート').last);
    await tester.tap(find.text('航行スタート').last);
    await tester.pumpAndSettle();

    expect(started, ['代漕']);
    // アカウントの名前は変わらない。
    expect(await AccountDisplayNameService().load(), '後藤');
  });
}
