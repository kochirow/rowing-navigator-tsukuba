import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/theme/boat_palette.dart';

void main() {
  group('BoatPalette', () {
    test('自艇の赤は識別色パレットに入っていない', () {
      // 赤は「自艇」と「危険」に予約する。他艇へ配ると意味が薄れる。
      expect(BoatPalette.trackPalette, isNot(contains(BoatPalette.myBoat)));
    });

    test('識別色は重複しない', () {
      expect(
        BoatPalette.trackPalette.toSet().length,
        BoatPalette.trackPalette.length,
      );
    });

    test('識別色はすべて暗めで、白縁が効く', () {
      // getBoatHomePlateBitmapDescriptor は luminance > 0.5 で黒縁へ切り替える。
      // パレット内で縁の色が混ざると、艇印の見た目が艇ごとに変わってしまう。
      for (final color in BoatPalette.trackPalette) {
        expect(color.computeLuminance(), lessThan(0.5), reason: '$color');
      }
      expect(BoatPalette.otherBoat.computeLuminance(), lessThan(0.5));
    });
  });

  group('boatColorHash', () {
    test('同じ艇IDは常に同じ値', () {
      expect(boatColorHash('boat-a'), boatColorHash('boat-a'));
    });

    test('末尾1文字だけ違うIDが同じ値にならない', () {
      final hashes = [
        for (var i = 0; i < 10; i++) boatColorHash('boat-$i'),
      ];
      expect(hashes.toSet().length, hashes.length);
    });
  });

  group('assignBoatTrackColors', () {
    test('同時に見えている艇どうしは色が重ならない', () {
      final ids = [for (var i = 0; i < 10; i++) 'boat-$i'];
      final assigned = assignBoatTrackColors(ids);
      expect(assigned.length, ids.length);
      expect(assigned.values.toSet().length, ids.length);
    });

    test('入力の順序が変わっても割り当ては同じ', () {
      final ids = ['delta', 'alpha', 'charlie', 'bravo'];
      final forward = assignBoatTrackColors(ids);
      final backward = assignBoatTrackColors(ids.reversed);
      expect(forward, backward);
    });

    test('艇が増えても、衝突しない艇の色は変わらない', () {
      // 監視中に1隻出艇するたび全艇の色が入れ替わると、色で追う意味が消える。
      final before = assignBoatTrackColors(['boat-1', 'boat-2', 'boat-3']);
      final after =
          assignBoatTrackColors(['boat-1', 'boat-2', 'boat-3', 'boat-4']);
      final kept = before.entries.where((e) => after[e.key] == e.value).length;
      expect(kept, greaterThanOrEqualTo(2));
    });

    test('艇数がパレットを超えても全艇へ色を配る', () {
      // 色分けを諦めても表示は続ける(原則1)。名前ラベルは常に出ている。
      final ids = [for (var i = 0; i < 16; i++) 'boat-$i'];
      final assigned = assignBoatTrackColors(ids);
      expect(assigned.length, ids.length);
      for (final id in ids) {
        expect(BoatPalette.trackPalette, contains(assigned[id]));
      }
    });

    test('艇がいなければ空', () {
      expect(assignBoatTrackColors(const []), isEmpty);
    });
  });
}
