import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/utils/rowing_navigation.dart';

void main() {
  group('rowingMapBearing', () {
    test('北へ進む艇では地図を180度回転して進行方向を画面下へ向ける', () {
      expect(rowingMapBearing(0), 180);
    });

    test('南へ進む艇では地図の方位を0度にする', () {
      expect(rowingMapBearing(180), 0);
    });

    test('負の方位と360度超を0〜360度へ正規化する', () {
      expect(rowingMapBearing(-90), 90);
      expect(rowingMapBearing(450), 270);
    });

    test('不正な方位でも有限値を返す', () {
      expect(rowingMapBearing(double.nan), 180);
      expect(rowingMapBearing(double.infinity), 180);
    });

    test('自艇マーカーの方位は実際の進行方位を使う', () {
      expect(normalizeBearing(-90), 270);
      expect(normalizeBearing(450), 90);
    });
  });
}
