import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/navigation_defaults_service.dart';
import 'package:rowing_navigator/types/boat_type.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('returns null before the first navigation is confirmed', () async {
    expect(await NavigationDefaultsService().load(), isNull);
  });

  test('saves and restores the last confirmed navigation settings', () async {
    final service = NavigationDefaultsService();
    await service.save(
      displayName: '後藤',
      boatType: BoatType.r_4x,
      seatPosition: 3,
      strokeRateEnabled: false,
      strokeMotionDisplayEnabled: true,
    );

    final restored = await service.load();
    expect(restored, isNotNull);
    expect(restored!.displayName, '後藤');
    expect(restored.boatType, BoatType.r_4x);
    expect(restored.seatPosition, 3);
    expect(restored.strokeRateEnabled, isFalse);
    expect(restored.strokeMotionDisplayEnabled, isTrue);
  });

  test('SPM設定が未保存ならレート計測を既定で有効にする', () async {
    SharedPreferences.setMockInitialValues({
      'navigation_display_name_v1': '後藤',
      'navigation_boat_type_v1': BoatType.r_1x.name,
      'navigation_seat_position_v1': 1,
    });

    final restored = await NavigationDefaultsService().load();
    expect(restored, isNotNull);
    expect(restored!.strokeRateEnabled, isTrue);
    expect(restored.strokeMotionDisplayEnabled, isFalse);
  });

  test('明示的に保存したSPM設定ONは維持する', () async {
    final service = NavigationDefaultsService();
    await service.save(
      displayName: '後藤',
      boatType: BoatType.r_1x,
      seatPosition: 1,
      strokeRateEnabled: true,
    );

    final restored = await service.load();
    expect(restored, isNotNull);
    expect(restored!.strokeRateEnabled, isTrue);
  });

  test('舟速分析表示は新規端末で既定OFF、航行中の切替を保存する', () async {
    final service = NavigationDefaultsService();
    await service.save(
      displayName: '後藤',
      boatType: BoatType.r_1x,
      seatPosition: 1,
    );
    expect((await service.load())!.strokeMotionDisplayEnabled, isFalse);

    await service.saveStrokeMotionDisplayEnabled(true);
    expect((await service.load())!.strokeMotionDisplayEnabled, isTrue);
  });
}
