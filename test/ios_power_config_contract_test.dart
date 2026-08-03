import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iPhoneで高リフレッシュレートを明示的に許可しない', () {
    final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();

    expect(
      infoPlist,
      contains(
        '<key>CADisableMinimumFrameDurationOnPhone</key>\n\t<false/>',
      ),
      reason: '地図表示に不要な高リフレッシュレートを許可すると、'
          '航行中の電池消費と発熱が増えるため。Flutterの自動移行による'
          'trueの再追加も防ぐため、キーはfalseで明示する。',
    );
  });

  test('IMU艇速融合のモーション利用目的をiOSへ明示する', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();

    expect(plist, contains('<key>NSMotionUsageDescription</key>'));
    expect(plist, contains('SPM、艇速変化、短時間のGPS誤差'));
  });
}
