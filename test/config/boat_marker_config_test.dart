import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/boat_config.dart';
import 'package:rowing_navigator/config/map_style_config.dart';

void main() {
  test('艇マーカーは衝突判定幅でなく実艇の船体幅を使う', () {
    for (final config in boatConfigs.allConfigs) {
      expect(config.displayHullWidthMeters, inInclusiveRange(0.5, 0.8));
      expect(
        config.displayHullWidthMeters,
        lessThan(config.shipDomainParams.shipBodyParam.w),
        reason: '${config.label}の矢羽が衝突判定ポリゴンと同じ太さに戻っています。',
      );
    }
  });

  test('縮小時の視認性下限は実寸表示を大きく邪魔しない', () {
    expect(minBoatMarkerLengthPixels, lessThanOrEqualTo(8));
  });
}
