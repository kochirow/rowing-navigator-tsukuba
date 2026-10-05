import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/map_style_config.dart';
import 'package:rowing_navigator/theme/boat_palette.dart';
import 'package:rowing_navigator/theme/hazard_palette.dart';

Color _styleColor(List<Map<String, dynamic>> style, String? featureType) {
  final rule = style.firstWhere(
    (e) => e['featureType'] == featureType && e['elementType'] == 'geometry',
  );
  final hex = (rule['stylers'] as List).cast<Map<String, dynamic>>().first;
  return Color(int.parse((hex['color'] as String).substring(1), radix: 16))
      .withValues(alpha: 1);
}

/// WCAG のコントラスト比。
double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  final style = (jsonDecode(navigationNightMapStyle) as List<dynamic>)
      .cast<Map<String, dynamic>>();

  test('夜の地図スタイルは正しいJSONで、水面の色を持つ', () {
    // JSON が壊れていると Google Maps は黙ってスタイルを無視し、明るい地図のまま走る。
    expect(style, isNotEmpty);
    expect(_styleColor(style, 'water'), const Color(0xFF17405A));
  });

  test('水面は、陸・危険区域・他艇を見分けられる明るさにする', () {
    // 見分けたい順は 岸(陸)・危険区域・他艇 で、自艇ではない(2026-10-06)。
    // 水面を暗くすれば自艇は浮くが陸と区別できず、明るくしすぎれば
    // 他艇の赤が沈む。両側から挟んで、片方だけを優先する変更を止める。
    final water = _styleColor(style, 'water');
    final land = _styleColor(style, null);
    expect(_contrast(water, land), greaterThan(1.8));
    expect(_contrast(water, BoatPalette.otherBoat), greaterThan(3.5));

    Color over(Color fg) => Color.alphaBlend(fg, water);
    for (final category in ['island', 'driftwood', 'bridgePier', 'pile']) {
      expect(
        _contrast(water, over(HazardPalette.nightStrokeColorOf(category))),
        greaterThan(6.0),
        reason: '$category の線',
      );
      expect(
        _contrast(water, over(HazardPalette.nightFillColorOf(category))),
        greaterThan(1.8),
        reason: '$category の塗り',
      );
    }
  });

  test('岸の塗りは、陸と水面の差を縮めない濃さにとどめる', () {
    // 岸の区域は陸側へも伸びる。白い塗りを濃くすると黒い陸が灰色になり、
    // 水面との差が逆に縮む。
    final water = _styleColor(style, 'water');
    final land = _styleColor(style, null);
    final shoreOnLand =
        Color.alphaBlend(HazardPalette.nightFillColorOf('shore'), land);
    expect(_contrast(water, shoreOnLand), greaterThan(1.7));
  });
}
