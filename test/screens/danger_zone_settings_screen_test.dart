import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/danger_zone_settings.dart';
import 'package:rowing_navigator/screens/danger_zone_settings_screen.dart';
import 'package:rowing_navigator/services/danger_zone_settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('岸・橋・島・固定流木の危険範囲を0〜30mで操作して保存できる', (tester) async {
    tester.view
      ..physicalSize = const Size(800, 3000)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const DangerZoneSettingsScreen(),
                  ),
                ),
                child: const Text('設定を開く'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('設定を開く'));
    await tester.pumpAndSettle();

    // スライダーは −/+ のステッパーになった(0.5m 刻み・0〜30m)。
    expect(find.byType(Slider), findsNothing);
    expect(find.text('固定流木'), findsOneWidget);
    expect(find.text('水上側'), findsOneWidget);
    expect(find.text('陸側'), findsOneWidget);
    expect(find.text('内側'), findsNWidgets(2));
    expect(find.text('外側'), findsNWidgets(2));
    expect(find.text('15.0 m'), findsOneWidget);

    // 変更があるときだけ下に保存バーが出る。
    expect(find.text('保存'), findsNothing);
    for (var i = 0; i < 15; i++) {
      await tester.tap(find.byKey(const ValueKey('zone-shore-water-plus')));
      await tester.pump();
    }
    expect(find.text('12.5 m'), findsOneWidget);
    expect(find.text('保存していない変更 1件'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final saved = await DangerZoneSettingsService().load();
    expect(saved[DangerZoneKind.shore].waterSideMeters, 12.5);
  });
}
