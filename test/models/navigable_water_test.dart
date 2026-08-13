import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/navigable_water.dart';

void main() {
  Map<String, dynamic> lane({Object? leg = 'outbound', bool withLeg = true}) =>
      {
        'id': 'lane_test',
        'name': 'テスト航路',
        'kind': 'lane',
        if (withLeg) 'leg': leg,
        'points': [
          {'lat': 36.069, 'lng': 140.208},
          {'lat': 36.070, 'lng': 140.208},
          {'lat': 36.070, 'lng': 140.209},
        ],
      };

  group('leg の読み取り', () {
    test('outbound / return を読める', () {
      expect(NavigableWater.fromJson(lane(leg: 'outbound')).leg, 'outbound');
      expect(NavigableWater.fromJson(lane(leg: 'return')).leg, 'return');
    });

    test('leg が無ければ null。例外は投げない', () {
      final water = NavigableWater.fromJson(lane(withLeg: false));

      expect(water.leg, isNull);
      // 表示用の付加情報1つで航路が消えないこと(原則1)。
      expect(water.points.length, 3);
    });

    test('不正な leg は null にし、レーン自体は残す', () {
      // 型違い・想定外の文字列・null。どれも「向きが不明な航路」として出す。
      for (final invalid in <Object?>[
        123,
        'foo',
        '',
        null,
        true,
        ['return']
      ]) {
        final water = NavigableWater.fromJson(lane(leg: invalid));

        expect(water.leg, isNull, reason: 'leg=$invalid');
        expect(water.id, 'lane_test');
        expect(water.points.length, 3);
      }
    });
  });

  group('既存の座標検証は変わらない', () {
    test('点が3つ未満なら弾く', () {
      final map = lane()
        ..['points'] = [
          {'lat': 36.069, 'lng': 140.208},
        ];

      expect(() => NavigableWater.fromJson(map), throwsFormatException);
    });

    test('範囲外の座標は弾く', () {
      final map = lane()
        ..['points'] = [
          {'lat': 36.069, 'lng': 140.208},
          {'lat': 36.070, 'lng': 140.208},
          {'lat': 999.0, 'lng': 140.209},
        ];

      expect(() => NavigableWater.fromJson(map), throwsFormatException);
    });

    test('kind が navigableWater / lane 以外なら弾く', () {
      final map = lane()..['kind'] = 'shore';

      expect(() => NavigableWater.fromJson(map), throwsFormatException);
    });

    test('id が空なら弾く', () {
      final map = lane()..['id'] = '';

      expect(() => NavigableWater.fromJson(map), throwsFormatException);
    });
  });
}
