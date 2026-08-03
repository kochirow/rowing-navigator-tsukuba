import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/theme/hazard_palette.dart';
import 'package:rowing_navigator/theme/map_layer_spec.dart';

void main() {
  group('laneStyleFor', () {
    test('往路と復路は線の色で区別する', () {
      final outbound = laneStyleFor(leg: 'outbound', isSatellite: false);
      final returnLeg = laneStyleFor(leg: 'return', isSatellite: false);
      expect(outbound.strokeColor, isNot(returnLeg.strokeColor));
      expect(outbound.fillColor, isNot(returnLeg.fillColor));
    });

    test('往路と復路の差は明度だけでつけ、太さ・濃さは揃える', () {
      // 片方だけ太く・濃くすると、そちらが危険区域より目立ってしまう。
      for (final isSatellite in [false, true]) {
        final outbound =
            laneStyleFor(leg: 'outbound', isSatellite: isSatellite);
        final returnLeg = laneStyleFor(leg: 'return', isSatellite: isSatellite);
        expect(outbound.strokeWidth, returnLeg.strokeWidth);
        expect(outbound.strokeColor.a, closeTo(returnLeg.strokeColor.a, 0.001));
        expect(outbound.fillColor.a, closeTo(returnLeg.fillColor.a, 0.001));
      }
    });

    test('leg が無い・不正なレーンは無彩色で描く(消さない)', () {
      // 表示用の付加情報1つで航路が1本まるごと消えるほうが害が大きい(原則1)。
      for (final leg in <String?>[null, 'unknown', '', 'OUTBOUND', '往路']) {
        for (final isSatellite in [false, true]) {
          final style = laneStyleFor(leg: leg, isSatellite: isSatellite);
          expect(
            style.strokeColor.withValues(alpha: 1.0),
            const Color(0xFF9E9E9E),
            reason: 'leg=$leg は無彩色になること',
          );
          expect(style.fillColor, Colors.transparent);
          expect(style.strokeWidth, greaterThan(0));
        }
      }
    });

    test('航空写真と通常地図で色が変わる', () {
      for (final leg in ['outbound', 'return']) {
        expect(
          laneStyleFor(leg: leg, isSatellite: true).strokeColor,
          isNot(laneStyleFor(leg: leg, isSatellite: false).strokeColor),
        );
      }
    });

    test('航路の塗りは、いちばん薄い危険区域(岸)より必ず薄い', () {
      // 危険区域より航路が目立つ配色を恒久的に禁止する。帯は川幅いっぱいの
      // 面積があるため、少しでも濃いと岸・橋脚・中州の色を全部濁らせる。
      final shoreFillOpacity = HazardPalette.fillOpacityOf('shore');
      for (final leg in <String?>['outbound', 'return', null]) {
        for (final isSatellite in [false, true]) {
          expect(
            laneStyleFor(leg: leg, isSatellite: isSatellite).fillColor.a,
            lessThan(shoreFillOpacity),
            reason: 'leg=$leg / isSatellite=$isSatellite の塗りが岸より濃い',
          );
        }
      }
    });

    test('航路の線は、橋脚の輪郭より必ず細い', () {
      final bridgePierWidth = HazardPalette.strokeWidthOf('bridgePier');
      for (final leg in <String?>['outbound', 'return', null]) {
        for (final isSatellite in [false, true]) {
          expect(
            laneStyleFor(leg: leg, isSatellite: isSatellite).strokeWidth,
            lessThan(bridgePierWidth),
            reason: 'leg=$leg / isSatellite=$isSatellite の線が橋脚より太い',
          );
        }
      }
    });
  });

  test('zIndex は 航路 < シェブロン < 航跡 < 危険区域 < 予測 < 開発者 の順', () {
    // 「塗り = 実在する危険」が「帯 = 通ってよい場所」に沈まないことを守る。
    final order = [
      laneFillZIndex,
      laneChevronZIndex,
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
