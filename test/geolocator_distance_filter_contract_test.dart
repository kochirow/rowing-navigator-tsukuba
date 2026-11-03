import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('geolocator_appleの検証済みmapper版を固定する', () {
    final lock = File('pubspec.lock').readAsStringSync();
    final match =
        RegExp(r'geolocator_apple:[\s\S]*?version: "([^"]+)"').firstMatch(lock);
    expect(match, isNotNull);
    // 2.4.3 でも LocationDistanceMapper は -1 をそのまま
    // kCLDistanceFilterNone として渡すことを確認した(2026-11-04、R7)。
    expect(match!.group(1), '2.4.3',
        reason: '更新時はLocationDistanceMapperの-1経路を再確認する');
  });
}
