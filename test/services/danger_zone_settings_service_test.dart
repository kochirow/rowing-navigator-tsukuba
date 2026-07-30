import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/danger_zone_settings.dart';
import 'package:rowing_navigator/services/danger_zone_settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = DangerZoneSettingsService();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('変更した片側距離を区域種別ごとに保存して再読込できる', () async {
    final settings = DangerZoneSettings.defaults().withOffsets(
      DangerZoneKind.bridge,
      const DangerZoneOffsets(
        waterSideMeters: 8.5,
        landSideMeters: 18.0,
      ),
    );

    await service.save(settings);
    final loaded = await service.load();

    expect(loaded[DangerZoneKind.bridge].waterSideMeters, 8.5);
    expect(loaded[DangerZoneKind.bridge].landSideMeters, 18.0);
    expect(loaded[DangerZoneKind.shore].waterSideMeters, 5.0);
    expect(loaded[DangerZoneKind.shore].landSideMeters, 15.0);
    expect(loaded[DangerZoneKind.bridge].waterSideMeters, 8.5);
  });

  test('不正値はデフォルト、上限超過値は30mへ補正する', () async {
    SharedPreferences.setMockInitialValues({
      'danger_zone_offset_v1_shore_water': -1.0,
      'danger_zone_offset_v1_bridge_land': 30.5,
      'danger_zone_offset_v1_island_water': double.nan,
    });

    final loaded = await service.load();

    expect(loaded[DangerZoneKind.shore].waterSideMeters, 5.0);
    expect(loaded[DangerZoneKind.shore].landSideMeters, 15.0);
    expect(loaded[DangerZoneKind.bridge].waterSideMeters, 5.0);
    expect(loaded[DangerZoneKind.bridge].landSideMeters, 30.0);
    expect(loaded[DangerZoneKind.island].waterSideMeters, 5.0);
  });

  test('保存値を0.5m刻みに正規化する', () async {
    final settings = DangerZoneSettings.defaults().withOffsets(
      DangerZoneKind.driftwood,
      const DangerZoneOffsets(
        waterSideMeters: 12.24,
        landSideMeters: 12.26,
      ),
    );

    await service.save(settings);
    final loaded = await service.load();

    expect(loaded[DangerZoneKind.driftwood].waterSideMeters, 12.0);
    expect(loaded[DangerZoneKind.driftwood].landSideMeters, 12.5);
  });
}
