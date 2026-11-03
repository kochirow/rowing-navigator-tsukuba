import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/location_activity_config.dart';
import 'package:rowing_navigator/services/navigation_diagnostics_support.dart';

void main() {
  group('実際に効く用途指定(R7-R2)', () {
    String? effective(
      NavigationLocationActivity requested, {
      bool isIos = true,
      int? os,
      int? sdk,
    }) =>
        effectiveLocationActivityName(
          requested: requested,
          isIos: isIos,
          iosMajorVersion: os,
          sdkMajorVersion: sdk,
        );

    test('iOS 27 以上かつ iOS 27 の SDK のときだけ maritime', () {
      expect(effective(NavigationLocationActivity.maritime, os: 27, sdk: 27),
          'maritime');
      expect(effective(NavigationLocationActivity.maritime, os: 26, sdk: 27),
          'otherNavigation');
      expect(effective(NavigationLocationActivity.maritime, os: 27, sdk: 26),
          'otherNavigation');
    });

    test('fitness はそのまま、Android は対象外', () {
      expect(effective(NavigationLocationActivity.fitness), 'fitness');
      expect(effective(NavigationLocationActivity.maritime, isIos: false),
          'notApplicable');
    });

    test('版が読めなければ推測しない', () {
      expect(effective(NavigationLocationActivity.maritime, os: 27), isNull);
      expect(effective(NavigationLocationActivity.maritime, sdk: 27), isNull);
    });

    test('版の文字列から先頭のメジャー版を読む', () {
      expect(leadingMajorVersion('26.6.2'), 26);
      expect(leadingMajorVersion('iphoneos27.0'), 27);
      expect(leadingMajorVersion('unknown'), isNull);
      expect(leadingMajorVersion(null), isNull);
    });

    test('端末の情報から、指定・効いた種類・プラグインの版を記録する', () {
      final details = locationActivityDiagnostics(
        requested: NavigationLocationActivity.maritime,
        deviceSnapshot: const {
          'platform': 'iOS',
          'systemVersion': '26.6.2',
          'buildSdkName': 'iphoneos27.1',
        },
      );
      expect(details['locationActivityRequested'], 'maritime');
      expect(details['locationActivityEffective'], 'otherNavigation');
      expect(details['geolocatorAppleVersion'], geolocatorAppleVersion);
      // 端末の情報が無い記録(航行開始の時点)では、効いた種類を書かない。
      expect(
        locationActivityDiagnostics(
                requested: NavigationLocationActivity.maritime)
            .containsKey('locationActivityEffective'),
        isFalse,
      );
    });
  });

  test('記録する geolocator_apple の版は pubspec.lock と一致する', () {
    final lock = File('pubspec.lock').readAsStringSync();
    final match = RegExp(
      r'\n  geolocator_apple:\n(?:    .*\n)*?    version: "([^"]+)"',
    ).firstMatch(lock);
    expect(match, isNotNull);
    expect(match!.group(1), geolocatorAppleVersion);
  });
}
