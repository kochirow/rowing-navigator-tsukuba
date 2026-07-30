import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/utils/geo_proximity.dart';

void main() {
  group('minDistanceToPolygonMeters', () {
    // 約100m四方の正方形ポリゴン(緯度0.0009度 ≒ 100m)
    final square = [
      const LatLng(36.0670, 140.2040),
      const LatLng(36.0679, 140.2040),
      const LatLng(36.0679, 140.2051),
      const LatLng(36.0670, 140.2051),
    ];

    test('ポリゴン内部の点は距離0を返す', () {
      const inside = LatLng(36.0674, 140.2045);
      expect(minDistanceToPolygonMeters(inside, square), 0.0);
    });

    test('ポリゴン外部の点はおおよそ正しい距離を返す', () {
      // 南辺(lat=36.0670)から緯度0.0009度(約100m)南の点
      const outside = LatLng(36.0661, 140.2045);
      final distance = minDistanceToPolygonMeters(outside, square);
      expect(distance, greaterThan(90));
      expect(distance, lessThan(110));
    });

    test('境界のすぐ近くの点は小さい距離を返す', () {
      // 南辺から緯度0.00009度(約10m)南の点
      const nearEdge = LatLng(36.06691, 140.2045);
      final distance = minDistanceToPolygonMeters(nearEdge, square);
      expect(distance, greaterThan(5));
      expect(distance, lessThan(15));
    });

    test('頂点2点の不正なポリゴンは線分として距離を返す', () {
      const point = LatLng(36.0674, 140.2045);
      final invalid = [
        const LatLng(36.0670, 140.2040),
        const LatLng(36.0679, 140.2040),
      ];
      final distance = minDistanceToPolygonMeters(point, invalid);
      expect(distance, greaterThan(40));
      expect(distance, lessThan(50));
    });
  });
  group('nearestPointOnPolygon', () {
    // 岸の危険区域は基準線の各辺を長方形へ展開したものなので、重心方向は
    // 「どちら側に岸があるか」とほぼ無関係。方向案内には最寄りの辺を使う。
    final ribbon = [
      const LatLng(36.0670, 140.2040),
      const LatLng(36.0670, 140.2140), // 東西に約900m伸びる細長い帯
      const LatLng(36.0671, 140.2140),
      const LatLng(36.0671, 140.2040),
    ];

    test('細長い区域では重心ではなく最寄りの辺上の点を返す', () {
      // 帯の東端近く・南側の点。重心は遥か西にある。
      const point = LatLng(36.0665, 140.2135);
      final nearest = nearestPointOnPolygon(point, ribbon)!;

      expect(nearest.latitude, closeTo(36.0670, 1e-4));
      expect(nearest.longitude, closeTo(140.2135, 1e-3));
    });

    test('頂点が無ければnull、1点ならその点', () {
      expect(
          nearestPointOnPolygon(const LatLng(36.0, 140.0), const []), isNull);
      expect(
        nearestPointOnPolygon(
          const LatLng(36.0, 140.0),
          [const LatLng(36.1, 140.1)],
        ),
        const LatLng(36.1, 140.1),
      );
    });
  });
}
