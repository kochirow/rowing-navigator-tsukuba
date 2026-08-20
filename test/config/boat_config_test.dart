import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/boat_config.dart';
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
          closeTo(expectedSeconds[config.type]!, 1e-9),
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
}
