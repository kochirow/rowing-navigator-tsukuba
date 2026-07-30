import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/utils/sat_algorithm.dart';
import 'package:vector_math/vector_math.dart';

/// `polygonsOverlap` は `collision_risk_evaluator_service` から6箇所で呼ばれる
/// 「いま重なっているか」の判定。掃引(`ContinuousCollisionService`)が例外に
/// なったときのフォールバックでもあるため、ここが黙って false を返すと
/// 保守的判定そのものが働かない。
const _earthRadiusMeters = 6378137.0;
const _originLatitude = 36.08;
const _originLongitude = 140.12;

LatLng at(double east, double north) => LatLng(
      _originLatitude + north * 180 / (math.pi * _earthRadiusMeters),
      _originLongitude +
          east *
              180 /
              (math.pi *
                  _earthRadiusMeters *
                  math.cos(_originLatitude * math.pi / 180)),
    );

Polygon polygonOf(List<LatLng> points, {String id = 'p'}) =>
    Polygon(polygonId: PolygonId(id), points: points);

/// 中心 ([east], [north])、一辺 2×[halfSize] [m] の正方形。
Polygon square(double east, double north, double halfSize, {String id = 'p'}) =>
    polygonOf([
      at(east - halfSize, north - halfSize),
      at(east + halfSize, north - halfSize),
      at(east + halfSize, north + halfSize),
      at(east - halfSize, north + halfSize),
    ], id: id);

void main() {
  group('polygonsOverlap の基本', () {
    test('離れた2つは重ならない', () {
      expect(
        polygonsOverlap(square(0, 0, 5, id: 'a'), square(20, 0, 5, id: 'b')),
        isFalse,
      );
    });

    test('重なっていれば true', () {
      expect(
        polygonsOverlap(square(0, 0, 5, id: 'a'), square(8, 0, 5, id: 'b')),
        isTrue,
      );
    });

    test('内包していれば true', () {
      expect(
        polygonsOverlap(square(0, 0, 10, id: 'a'), square(0, 0, 2, id: 'b')),
        isTrue,
      );
    });

    test('辺が接するだけでも true(境界は含む側=安全側)', () {
      // 片方の右辺と、もう片方の左辺が一致する配置。
      expect(
        polygonsOverlap(square(0, 0, 5, id: 'a'), square(10, 0, 5, id: 'b')),
        isTrue,
      );
    });

    test('45度回した領域でも軸に依らず判定する', () {
      // 艇の領域は針路に応じて回転する。軸並行だけで通るテストにしない。
      final rotated = polygonOf([
        at(0, 7),
        at(7, 0),
        at(0, -7),
        at(-7, 0),
      ], id: 'diamond');

      // 菱形の頂点(東7m)と重なる正方形。
      expect(polygonsOverlap(rotated, square(9, 0, 3, id: 'b')), isTrue);
      // 角の外側にある正方形(中心間13.4m)。
      expect(polygonsOverlap(rotated, square(9, 9, 3, id: 'c')), isFalse);
    });

    test('凹んだ区域は、外接矩形が重なっても凹部では重ならない', () {
      // 三角形分割をしている理由そのもの。C字の内側の空洞に入る小区域。
      final cShape = polygonOf([
        at(-10, -10),
        at(10, -10),
        at(10, -6),
        at(-6, -6),
        at(-6, 6),
        at(10, 6),
        at(10, 10),
        at(-10, 10),
      ], id: 'c-shape');

      // 空洞の中(東2m・北0m)。外接矩形には入るが、実体には触れない。
      expect(polygonsOverlap(cShape, square(2, 0, 2, id: 'inner')), isFalse);
      // 下側の腕に重なる位置。
      expect(polygonsOverlap(cShape, square(2, -8, 2, id: 'arm')), isTrue);
    });
  });

  group('度空間の非等方性が結果を変えない', () {
    // `polygonsOverlap` は緯度経度を**そのまま**平面座標として扱う
    // (`Vector2(latitude, longitude)`)。緯度36°では経度1度の実距離が
    // 緯度1度の約0.808倍しかないため、度空間の図形は東西方向へ引き伸ばされる。
    // 重なり判定はアフィン変換で不変なので結論は変わらない、というのが
    // この実装が成立している根拠(2026-07-27 レビュー C3)。ここで固定する。

    test('前提: 同じ実距離でも度の差は東西と南北で 0.808 倍ずれる', () {
      final east = at(100, 0);
      final north = at(0, 100);
      final longitudeDelta = (east.longitude - _originLongitude).abs();
      final latitudeDelta = (north.latitude - _originLatitude).abs();

      // 同じ100mでも、度で見ると経度側が 1/0.808 = 1.238倍 大きい。
      expect(
        latitudeDelta / longitudeDelta,
        closeTo(math.cos(_originLatitude * math.pi / 180), 1e-9),
      );
    });

    test('東西と南北で同じ実距離なら、同じ判定になる', () {
      final center = square(0, 0, 5, id: 'center');

      // 実距離で 2m の隙間(縁 5m と 7m)。どちらの向きでも重ならない。
      expect(polygonsOverlap(center, square(12, 0, 5, id: 'e')), isFalse);
      expect(polygonsOverlap(center, square(-12, 0, 5, id: 'w')), isFalse);
      expect(polygonsOverlap(center, square(0, 12, 5, id: 'n')), isFalse);
      expect(polygonsOverlap(center, square(0, -12, 5, id: 's')), isFalse);

      // 実距離で 1m 重なる配置。どちらの向きでも重なる。
      expect(polygonsOverlap(center, square(9, 0, 5, id: 'e2')), isTrue);
      expect(polygonsOverlap(center, square(-9, 0, 5, id: 'w2')), isTrue);
      expect(polygonsOverlap(center, square(0, 9, 5, id: 'n2')), isTrue);
      expect(polygonsOverlap(center, square(0, -9, 5, id: 's2')), isTrue);
    });

    test('斜め45度でも東西・南北で対称', () {
      final center = square(0, 0, 5, id: 'center');
      // 中心間の実距離を揃えた4象限。いずれも同じ結論になる。
      // 軸並行の正方形どうしなので、東西・南北のどちらかで縁(10m)が
      // 離れていれば重ならない。
      for (final sign in [
        [1, 1],
        [1, -1],
        [-1, 1],
        [-1, -1],
      ]) {
        expect(
          polygonsOverlap(
            center,
            square(12.0 * sign[0], 12.0 * sign[1], 5, id: 'far'),
          ),
          isFalse,
          reason: '$sign',
        );
        expect(
          polygonsOverlap(
            center,
            square(6.0 * sign[0], 6.0 * sign[1], 5, id: 'near'),
          ),
          isTrue,
          reason: '$sign',
        );
      }
    });
  });

  group('checkPolygonsOverlap(凸同士のSAT)', () {
    List<Vector2> triangle(double x, double y) => [
          Vector2(x, y),
          Vector2(x + 1, y),
          Vector2(x, y + 1),
        ];

    test('分離軸があれば false', () {
      expect(checkPolygonsOverlap(triangle(0, 0), triangle(5, 0)), isFalse);
    });

    test('重なれば true', () {
      expect(checkPolygonsOverlap(triangle(0, 0), triangle(0.5, 0)), isTrue);
    });

    test('projectPolygon は軸への射影の最小・最大を返す', () {
      final range = projectPolygon(
        [Vector2(0, 0), Vector2(3, 0), Vector2(0, 4)],
        Vector2(1, 0),
      );
      expect(range[0], 0);
      expect(range[1], 3);
    });
  });

  group('退化した入力', () {
    test('頂点が3点に満たない区域は例外になる(呼び出し側で捕捉する前提)', () {
      expect(
        () => polygonsOverlap(
          polygonOf([at(0, 0), at(5, 0)], id: 'line'),
          square(0, 0, 5, id: 'b'),
        ),
        throwsException,
      );
    });

    test('共線に潰れた区域は例外になる', () {
      expect(
        () => polygonsOverlap(
          polygonOf([at(0, 0), at(5, 0), at(10, 0), at(2, 0)], id: 'flat'),
          square(0, 0, 5, id: 'b'),
        ),
        throwsException,
      );
    });

    test('自己交差(蝶ネクタイ)は例外にならず、重なりを見落とさない', () {
      // 実測(P02)どおり耳刈り取りは蝶ネクタイで必ずしも例外にならない。
      // 分割結果は元の形と一致しないが、外れる向きは警告を増やす側。
      final bowtie = polygonOf([
        at(-10, -10),
        at(10, -10),
        at(-10, 10),
        at(10, 10),
      ], id: 'bowtie');

      expect(polygonsOverlap(bowtie, square(0, 0, 2, id: 'center')), isTrue);
    });
  });
}
