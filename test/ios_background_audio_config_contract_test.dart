import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iPhoneはロック中の航行警告に必要な音声と位置情報を許可する', () {
    final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();

    expect(infoPlist, contains('<key>UIBackgroundModes</key>'));
    expect(infoPlist, contains('<string>audio</string>'));
    expect(infoPlist, contains('<string>location</string>'));
  });
}
