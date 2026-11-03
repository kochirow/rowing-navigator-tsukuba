import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:rowing_navigator/config/location_activity_config.dart';
import 'package:rowing_navigator/config/navigator_config.dart';
import 'package:rowing_navigator/services/geo_service.dart';
import 'package:rowing_navigator/services/location_activity_settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('iOS位置streamはkCLDistanceFilterNone(-1)を渡す', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final settings =
        GeoService().locationSettingsForTesting(LocationAccuracy.best);
    expect(settings, isA<AppleSettings>());
    expect((settings as AppleSettings).distanceFilter, iosDistanceFilterNone);
  });

  test('Androidの1秒設定とdistanceFilter 0は変えない', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final settings =
        GeoService().locationSettingsForTesting(LocationAccuracy.best);
    expect(settings, isA<AndroidSettings>());
    final android = settings as AndroidSettings;
    expect(android.distanceFilter, 0);
    expect(android.intervalDuration, const Duration(seconds: 1));
  });

  test('一発取得だけに使うtimeLimitは保持する', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final settings = GeoService().locationSettingsForTesting(
      LocationAccuracy.best,
      timeLimit: const Duration(seconds: 15),
    );
    expect(settings.timeLimit, const Duration(seconds: 15));
  });

  group('航行中の位置取得の用途指定(R7)', () {
    test('既定は maritime を渡す', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final geo = GeoService();
      expect(geo.navigationActivity, NavigationLocationActivity.maritime);
      final settings = geo.locationSettingsForTesting(LocationAccuracy.best)
          as AppleSettings;
      expect(settings.activityType, ActivityType.maritime);
      // 背面での継続は変えない(R7-R5)。
      expect(settings.pauseLocationUpdatesAutomatically, isFalse);
      expect(settings.allowBackgroundLocationUpdates, isTrue);
    });

    test('端末で fitness に戻すと、読み直した後の航行から fitness を渡す', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      SharedPreferences.setMockInitialValues({});
      await LocationActivitySettingsService()
          .save(NavigationLocationActivity.fitness);
      final geo = GeoService();
      expect(await geo.refreshNavigationActivity(),
          NavigationLocationActivity.fitness);
      final settings = geo.locationSettingsForTesting(LocationAccuracy.best)
          as AppleSettings;
      expect(settings.activityType, ActivityType.fitness);
    });

    test('既定へ戻すと保存値を消し、既定に従う', () async {
      SharedPreferences.setMockInitialValues({});
      final service = LocationActivitySettingsService();
      await service.save(NavigationLocationActivity.fitness);
      await service.save(NavigationLocationActivity.maritime);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
      expect(await service.load(), defaultNavigationLocationActivity);
    });
  });
}
