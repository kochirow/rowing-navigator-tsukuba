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

    final sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
    // 先頭2本は本警告/予告。その後に岸・橋・中州の2方向と流木周囲が並ぶ。
    expect(sliders, hasLength(9));
    for (final slider in sliders.skip(2)) {
      expect(slider.min, minDangerZoneOffsetMeters);
      expect(slider.max, maxDangerZoneOffsetMeters);
      expect(slider.divisions, 60);
      expect(slider.onChanged, isNotNull);
    }
    expect(find.text('固定流木'), findsOneWidget);
    expect(find.text('水上側: 5.0 m'), findsOneWidget);
    expect(find.text('陸側: 15.0 m'), findsOneWidget);
    expect(find.text('内側: 5.0 m'), findsNWidgets(2));
    expect(find.text('外側: 5.0 m'), findsNWidgets(2));

    sliders[2].onChanged!(12.5);
    await tester.pump();
    expect(find.text('水上側: 12.5 m'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final saved = await DangerZoneSettingsService().load();
    expect(saved[DangerZoneKind.shore].waterSideMeters, 12.5);
  });
}
