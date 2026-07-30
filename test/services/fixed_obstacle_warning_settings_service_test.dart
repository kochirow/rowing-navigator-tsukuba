import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/fixed_obstacle_warning_settings.dart';
import 'package:rowing_navigator/services/fixed_obstacle_warning_settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('初期状態では島2（上流）だけを警告対象から外す', () async {
    final settings = await FixedObstacleWarningSettingsService().load();

    expect(settings.isEnabled('island_upstream'), isFalse);
    expect(settings.isEnabled('island_sakuragawa_bridge'), isTrue);
    expect(settings.isEnabled('bridge_suigo'), isTrue);
  });

  test('対象物ごとのオン・オフを端末内へ保存できる', () async {
    final service = FixedObstacleWarningSettingsService();
    final saved = FixedObstacleWarningSettings().withEnabled(
      'bridge_suigo',
      false,
    );

    await service.save(saved);
    final restored = await service.load();

    expect(restored.isEnabled('island_upstream'), isFalse);
    expect(restored.isEnabled('bridge_suigo'), isFalse);
  });

  test('破損または未知IDの保存値は安全な初期状態へ戻す', () async {
    SharedPreferences.setMockInitialValues({
      'fixed_obstacle_warning_settings_v1': '["unknown"]',
    });

    final settings = await FixedObstacleWarningSettingsService().load();

    expect(settings.isEnabled('island_upstream'), isFalse);
    expect(settings.isEnabled('bridge_suigo'), isTrue);
  });
}
