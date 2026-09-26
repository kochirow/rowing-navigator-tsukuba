import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/map_style_config.dart';

void main() {
  test('夜の地図スタイルは正しいJSONで、水面の色を持つ', () {
    // JSON が壊れていると Google Maps は黙ってスタイルを無視し、明るい地図のまま走る。
    final decoded = jsonDecode(navigationNightMapStyle) as List<dynamic>;
    expect(decoded, isNotEmpty);
    final water = decoded.cast<Map<String, dynamic>>().firstWhere(
          (e) => e['featureType'] == 'water',
        );
    expect(jsonEncode(water), contains('#123142'));
  });
}
