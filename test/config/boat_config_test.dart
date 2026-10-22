import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/boat_config.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import 'package:rowing_navigator/types/boat_type.dart';

void main() {
  test('艇種別の停止時間を安全仕様の継承値として固定する', () {
    const expectedSeconds = <BoatType, double>{
      BoatType.r_1x: 6.95,
      BoatType.r_2x: 6.60,
      BoatType.r_4x: 6.68,
      BoatType.r_8p: 8.15,
    };

    for (final config in boatConfigs.allConfigs) {
      for (final speed in [2.0, 3.5, 5.0]) {
        final stoppingDistance = config.stoppingDistanceFormula(speed);
        expect(
          stoppingDistance / speed,
          closeTo(expectedSeconds[config.type.sizeClass]!, 1e-9),
          reason: '${config.label} ${speed}m/s',
        );
      }
    }
  });

  test('船体・排他領域は正で六角形の凸条件を守る', () {
    for (final config in boatConfigs.allConfigs) {
      for (final domain in [
        config.shipDomainParams.shipBodyParam,
        config.shipDomainParams.exclusiveParam,
      ]) {
        expect(domain.h, greaterThan(0), reason: config.label);
        expect(domain.w, greaterThan(0), reason: config.label);
        expect(domain.s, greaterThan(0), reason: config.label);
        expect(
          domain.s,
          lessThanOrEqualTo(domain.h),
          reason: '${config.label}: s <= h で凸性を保つ',
        );
      }
    }
  });

  test('全艇種を航行開始シートに出す', () {
    expect(
      boatConfigs.allConfigs.map((c) => c.label),
      ['1x', '2-', '2x', '2+', '4-', '4x', '4+', '8+'],
    );
  });

  test('人数が同じ艇種は大きさの区分と同じ寸法・停止距離を使う', () {
    for (final config in boatConfigs.allConfigs) {
      final base = boatConfigs.byBoatType(config.type.sizeClass);
      expect(
        identical(config.shipDomainParams, base.shipDomainParams),
        isTrue,
        reason: config.label,
      );
      expect(config.displayHullWidthMeters, base.displayHullWidthMeters);
      expect(
        config.stoppingDistanceFormula(4.0),
        base.stoppingDistanceFormula(4.0),
        reason: config.label,
      );
    }
  });

  test('2+ と 4+ の cox はバウ側(船首から1番目)に乗る', () {
    for (final type in [BoatType.r_2p, BoatType.r_4p]) {
      final seats = boatConfigs.byBoatType(type).seatPosList;
      final cox = seats.singleWhere((seat) => seat.label == 'cox');
      final bow = seats.singleWhere((seat) => seat.label == 'bow');
      expect(cox.position, 1, reason: type.displayLabel);
      expect(bow.position, 2, reason: type.displayLabel);
      // 端末を cox に置いたら、艇の中心より船首側にいる。
      expect(Boat.getSeatOffset(type, cox), greaterThan(0));
    }
    // 8+ の cox は艇尾のまま。
    final eight = boatConfigs.r_8p.seatPosList;
    final cox8 = eight.singleWhere((seat) => seat.label == 'cox');
    expect(Boat.getSeatOffset(BoatType.r_8p, cox8), lessThan(0));
  });

  test('シートの番号は艇種ごとに重複せず1から連続する', () {
    for (final config in boatConfigs.allConfigs) {
      final positions = config.seatPosList.map((s) => s.position).toList()
        ..sort();
      expect(
        positions,
        List.generate(positions.length, (i) => i + 1),
        reason: config.label,
      );
    }
  });
}
