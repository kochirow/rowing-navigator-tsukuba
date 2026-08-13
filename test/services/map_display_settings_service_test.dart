import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/map_display_settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('航路表示のトグル', () {
    test('未保存なら true(既定ON)', () async {
      // 右側通行の片側1レーンで運用しているため、どちらの帯にいるかは
      // 常に必要な情報である。既定でONにする。
      expect(await MapDisplaySettingsService().loadShowChannelLanes(), isTrue);
    });

    test('保存した値を読み戻せる', () async {
      final service = MapDisplaySettingsService();

      await service.saveShowChannelLanes(false);
      expect(await service.loadShowChannelLanes(), isFalse);

      await service.saveShowChannelLanes(true);
      expect(await service.loadShowChannelLanes(), isTrue);
    });

    test('他の表示設定と独立している', () async {
      final service = MapDisplaySettingsService();

      await service.saveShowChannelLanes(false);

      expect(await service.loadHighContrast(), isFalse);
      expect(await service.loadDeveloperSafetyShapeOverlay(), isFalse);
      expect(await service.loadShowChannelLanes(), isFalse);
    });
  });

  group('既存の表示設定は既定OFF', () {
    test('高コントラスト表示', () async {
      expect(await MapDisplaySettingsService().loadHighContrast(), isFalse);
    });

    test('開発者オーバーレイ', () async {
      expect(
        await MapDisplaySettingsService().loadDeveloperSafetyShapeOverlay(),
        isFalse,
      );
    });
  });
}
