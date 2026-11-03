import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/harbor_area.dart';

void main() {
  Map<String, dynamic> area({
    Object? id = 'harbor_laxmarina',
    Object? name = 'ラクスマリーナの港の中',
    Object? kind = 'harborArea',
    Object? points,
  }) =>
      {
        'id': id,
        'name': name,
        'kind': kind,
        'points': points ??
            [
              {'lat': 36.0810, 'lng': 140.2130},
              {'lat': 36.0830, 'lng': 140.2130},
              {'lat': 36.0830, 'lng': 140.2180},
            ],
      };

  test('正しい港の中を読める', () {
    final parsed = HarborArea.fromJson(area());
    expect(parsed.id, 'harbor_laxmarina');
    expect(parsed.points, hasLength(3));
    expect(
        () => parsed.points.add(parsed.points.first), throwsUnsupportedError);
  });

  test('kind が違うものは港の中として読まない', () {
    // 桟橋エリア(両者停止で他艇を無音)と港の中(控えめに鳴らす)は意味が違う。
    expect(() => HarborArea.fromJson(area(kind: 'mooringArea')),
        throwsFormatException);
  });

  test('壊れた入力は例外にする(呼び出し側が1件だけスキップする)', () {
    final invalid = <Map<String, dynamic>>[
      area(id: ''),
      area(name: null),
      area(points: [
        {'lat': 36.0810, 'lng': 140.2130},
        {'lat': 36.0830, 'lng': 140.2130},
      ]),
      area(points: [
        {'lat': 91.0, 'lng': 140.2130},
        {'lat': 36.0830, 'lng': 140.2130},
        {'lat': 36.0830, 'lng': 140.2180},
      ]),
      area(points: 'not a list'),
    ];
    for (final raw in invalid) {
      expect(() => HarborArea.fromJson(raw), throwsFormatException,
          reason: '$raw');
    }
  });
}
