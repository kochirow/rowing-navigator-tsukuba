import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/theme/hazard_palette.dart';
import 'package:rowing_navigator/theme/map_layer_spec.dart';

void main() {
  group('channelDividerStyleFor', () {
    test('芯より縁取りが太い(縁取りが芯の下から食み出す)', () {
      for (final isSatellite in [false, true]) {
        final style = channelDividerStyleFor(isSatellite: isSatellite);
        expect(style.casingWidth, greaterThan(style.coreWidth));
      }
    });

    test('必ず破線として描ける', () {
      // 実線は「実在するものの輪郭」、破線は「越えられるが越えない取り決め」。
      // 中央線が実線になると、岸や橋脚と同じ意味に読めてしまう。
      for (final isSatellite in [false, true]) {
        final style = channelDividerStyleFor(isSatellite: isSatellite);
        expect(style.dashLengthPixels, greaterThan(0));
        expect(style.gapLengthPixels, greaterThan(0));
      }
    });

    test('芯は下地によらず不透明寄りの白', () {
      // 通常地図(淡い水色)でも航空写真(暗い)でも同じ見え方にする。
      for (final isSatellite in [false, true]) {
        final style = channelDividerStyleFor(isSatellite: isSatellite);
        expect(style.coreColor.r, 1.0);
        expect(style.coreColor.g, 1.0);
        expect(style.coreColor.b, 1.0);
        expect(style.coreColor.a, greaterThan(0.9));
      }
    });

    test('縁取りは下地に合わせて変える', () {
      expect(
        channelDividerStyleFor(isSatellite: true).casingColor,
        isNot(channelDividerStyleFor(isSatellite: false).casingColor),
      );
    });

    test('中央線は、実在する危険(橋脚)の輪郭より太くしない', () {
      // 主役は危険区域である。中央線を目立たせるのは色と破線であって、
      // 太さで危険区域を上回ってはいけない。
      final bridgePierWidth = HazardPalette.strokeWidthOf('bridgePier');
      for (final isSatellite in [false, true]) {
        expect(
          channelDividerStyleFor(isSatellite: isSatellite).coreWidth,
          lessThanOrEqualTo(bridgePierWidth),
        );
      }
    });
  });

  test('zIndex は 中央線 < 航跡 < 危険区域 < 予測 < 開発者 の順', () {
    // 「塗り = 実在する危険」が「破線 = 取り決め」に沈まないことを守る。
    final order = [
      channelDividerZIndex,
      coachTrailZIndex,
      hazardPolygonZIndex,
      predictionShapeZIndex,
      developerOverlayZIndex,
    ];
    for (var index = 1; index < order.length; index++) {
      expect(order[index], greaterThan(order[index - 1]));
    }
  });
}
