import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/mooring_area.dart';

void main() {
  Map<String, dynamic> area({
    Object? id = 'mooring_boathouse',
    Object? name = '艇庫前桟橋',
    Object? kind = 'mooringArea',
    Object? points,
  }) =>
      {
        'id': id,
        'name': name,
        'kind': kind,
        'points': points ??
            [
              {'lat': 36.0830, 'lng': 140.2140},
              {'lat': 36.0830, 'lng': 140.2150},
              {'lat': 36.0836, 'lng': 140.2150},
            ],
      };

  test('正しい桟橋エリアを読める', () {
    final parsed = MooringArea.fromJson(area());

    expect(parsed.id, 'mooring_boathouse');
    expect(parsed.name, '艇庫前桟橋');
    expect(parsed.points, hasLength(3));
    expect(
      () => parsed.points.add(parsed.points.first),
      throwsUnsupportedError,
    );
  });

  test('kind が違うものは桟橋エリアとして読まない', () {
    // 陸上エリアと桟橋エリアは意味が違う。取り違えると、陸上判定のつもりが
    // 他艇の静音になる(またはその逆)。
    expect(
      () => MooringArea.fromJson(area(kind: 'ashoreArea')),
      throwsFormatException,
    );
  });

  test('壊れた入力は例外にする(呼び出し側が1件だけスキップする)', () {
    final invalid = <Map<String, dynamic>>[
      area(id: ''),
      area(id: 123),
      area(name: null),
      // 3点未満はポリゴンにならない。
      area(points: [
        {'lat': 36.0830, 'lng': 140.2140},
        {'lat': 36.0830, 'lng': 140.2150},
      ]),
      // 範囲外の座標。
      area(points: [
        {'lat': 91.0, 'lng': 140.2140},
        {'lat': 36.0830, 'lng': 140.2150},
        {'lat': 36.0836, 'lng': 140.2150},
      ]),
      // 数値でない座標。
      area(points: [
        {'lat': 'x', 'lng': 140.2140},
        {'lat': 36.0830, 'lng': 140.2150},
        {'lat': 36.0836, 'lng': 140.2150},
      ]),
    ];
    for (final json in invalid) {
      expect(() => MooringArea.fromJson(json), throwsFormatException);
    }
  });
}
