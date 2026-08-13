import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:rowing_navigator/config/navigator_config.dart';
import 'package:rowing_navigator/services/geo_service.dart';

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
}
