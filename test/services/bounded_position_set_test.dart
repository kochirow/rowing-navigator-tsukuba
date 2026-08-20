import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/services/bounded_position_set.dart';

void main() {
  test('円のMinkowski和は時間と速度に対して単調に増える', () {
    const set =
        CircleSet(representativePoint: LatLng(36, 140), radiusMeters: 2);
    final grown = set.grownBy(
      elapsed: const Duration(seconds: 3),
      speedMetersPerSecond: 2,
      headingDegrees: 0,
      headingReliable: false,
    );
    expect(grown.boundingRadiusMeters, 8);
  });

  test('円の交差は対称で、離れた円とは交差しない', () {
    const a = CircleSet(representativePoint: LatLng(36, 140), radiusMeters: 10);
    const b =
        CircleSet(representativePoint: LatLng(36.00005, 140), radiusMeters: 2);
    const far =
        CircleSet(representativePoint: LatLng(36.01, 140), radiusMeters: 2);
    expect(a.intersectsSet(b), b.intersectsSet(a));
    expect(a.intersectsSet(b), isTrue);
    expect(a.intersectsSet(far), isFalse);
  });

  test('ポリゴン内の中心又は辺に届く円を検出する', () {
    const set =
        CircleSet(representativePoint: LatLng(36, 140), radiusMeters: 8);
    const near = <LatLng>[
      LatLng(36.00005, 139.99995),
      LatLng(36.00005, 140.00005),
      LatLng(36.00015, 140.00005),
      LatLng(36.00015, 139.99995),
    ];
    expect(set.intersectsPolygon(near), isTrue);
  });

  test('停止時のカプセルは方位不明なら円へ縮退する', () {
    const set = CapsuleSet(
      start: LatLng(36, 140),
      end: LatLng(36, 140),
      radiusMeters: 2,
    );
    final grown = set.grownBy(
      elapsed: const Duration(seconds: 3),
      speedMetersPerSecond: 0,
      headingDegrees: 0,
      headingReliable: false,
    );
    expect(grown, isA<CircleSet>());
    expect(grown.boundingRadiusMeters, 2);
  });

  test('航行カプセルは前方へ伸び、全方向へ同じ長さを足さない', () {
    const set = CapsuleSet(
      start: LatLng(36, 140),
      end: LatLng(36, 140),
      radiusMeters: 2,
    );
    final grown = set.grownBy(
      elapsed: const Duration(seconds: 3),
      speedMetersPerSecond: 4,
      headingDegrees: 0,
      headingReliable: true,
    ) as CapsuleSet;
    // 横半幅は測位2m + 旋回分3.6mで、前方13.8mを横へ複製しない。
    expect(grown.radiusMeters, closeTo(5.6, .01));
    expect(grown.radiusMeters, lessThan(12));
  });

  test('離れた共線カプセルは交差しない', () {
    const first = CapsuleSet(
      start: LatLng(36, 140),
      end: LatLng(36, 140.00001),
      radiusMeters: 0,
    );
    const detached = CapsuleSet(
      start: LatLng(36, 140.00002),
      end: LatLng(36, 140.00003),
      radiusMeters: 0,
    );
    const overlapping = CapsuleSet(
      start: LatLng(36, 140.000005),
      end: LatLng(36, 140.000015),
      radiusMeters: 0,
    );

    expect(first.intersectsSet(detached), isFalse);
    expect(first.intersectsSet(overlapping), isTrue);
  });

  test('離れたポリゴンの共線辺を現在接触中と判定しない', () {
    const set = CapsuleSet(
      start: LatLng(36, 140),
      end: LatLng(36, 140.00001),
      radiusMeters: 0,
    );
    const detachedPolygon = <LatLng>[
      LatLng(36, 140.00002),
      LatLng(36, 140.00003),
      LatLng(36.00001, 140.00003),
      LatLng(36.00001, 140.00002),
    ];
    const touchingPolygon = <LatLng>[
      LatLng(36, 140.000005),
      LatLng(36, 140.000015),
      LatLng(36.00001, 140.000015),
      LatLng(36.00001, 140.000005),
    ];

    expect(set.intersectsPolygon(detachedPolygon), isFalse);
    expect(set.intersectsPolygon(touchingPolygon), isTrue);
  });
}
