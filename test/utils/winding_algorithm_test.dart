import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/utils/winding_algorithm.dart';

/// `isPointInPolygon` はカーブ・逆走の区域進入判定
/// (`evaluateEntryGuidanceRisk`)と描画で使う。**符号だけを見る**ため、
/// 緯度経度をそのまま平面座標として扱ってよい、というのが成立の根拠
/// (2026-07-27 レビュー C3)。ここで固定する。
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

List<LatLng> square(double east, double north, double halfSize) => [
      at(east - halfSize, north - halfSize),
      at(east + halfSize, north - halfSize),
      at(east + halfSize, north + halfSize),
      at(east - halfSize, north + halfSize),
    ];

void main() {
  group('凸な区域', () {
    final zone = square(0, 0, 50);

    test('内部の点は true', () {
      expect(isPointInPolygon(at(0, 0), zone), isTrue);
      expect(isPointInPolygon(at(45, 45), zone), isTrue);
      expect(isPointInPolygon(at(-45, -45), zone), isTrue);
    });

    test('外部の点は false', () {
      expect(isPointInPolygon(at(60, 0), zone), isFalse);
      expect(isPointInPolygon(at(0, 60), zone), isFalse);
      expect(isPointInPolygon(at(-60, -60), zone), isFalse);
    });

    test('東西と南北で同じ実距離なら同じ判定になる(度の非等方性に依らない)', () {
      // 緯度36°では経度1度の実距離が緯度1度の約0.808倍。度空間では図形が
      // 東西へ引き伸ばされるが、winding number は符号だけを見るため
      // 結論は変わらない。
      for (final distance in [10.0, 49.0, 51.0, 100.0]) {
        final inside = distance < 50;
        expect(isPointInPolygon(at(distance, 0), zone), inside,
            reason: '東 $distance m');
        expect(isPointInPolygon(at(-distance, 0), zone), inside,
            reason: '西 $distance m');
        expect(isPointInPolygon(at(0, distance), zone), inside,
            reason: '北 $distance m');
        expect(isPointInPolygon(at(0, -distance), zone), inside,
            reason: '南 $distance m');
      }
    });
  });

  group('周回の向き', () {
    test('反時計回りなら内部の winding number は +1', () {
      final ccw = square(0, 0, 50);
      expect(windingNumber(at(0, 0), ccw), 1);
    });

    test('時計回りなら −1 になるが、内外の判定は変わらない', () {
      // 危険区域データの頂点順は保証されていない。判定が向きに依存すると、
      // 逆順で登録された区域だけ進入判定が効かなくなる。
      final cw = square(0, 0, 50).reversed.toList();
      expect(windingNumber(at(0, 0), cw), -1);
      expect(isPointInPolygon(at(0, 0), cw), isTrue);
      expect(isPointInPolygon(at(60, 0), cw), isFalse);
    });
  });

  group('凹んだ区域', () {
    // C字。東側が開いた空洞を持つ。
    final cShape = [
      at(-30, -30),
      at(30, -30),
      at(30, -20),
      at(-20, -20),
      at(-20, 20),
      at(30, 20),
      at(30, 30),
      at(-30, 30),
    ];

    test('腕の内側は true', () {
      expect(isPointInPolygon(at(0, -25), cShape), isTrue);
      expect(isPointInPolygon(at(0, 25), cShape), isTrue);
      expect(isPointInPolygon(at(-25, 0), cShape), isTrue);
    });

    test('空洞の中は false(外接矩形には入る)', () {
      expect(isPointInPolygon(at(0, 0), cShape), isFalse);
      expect(isPointInPolygon(at(25, 0), cShape), isFalse);
    });
  });

  group('isLeft', () {
    test('進行方向の左側で正、右側で負、線上で0', () {
      final start = at(0, 0);
      final end = at(0, 100); // 真北へ向かう辺
      // 経度x・緯度yの右手系では、北向きの辺に対して西(左)が正。
      expect(isLeft(start, end, at(-10, 50)), greaterThan(0));
      expect(isLeft(start, end, at(10, 50)), lessThan(0));
      expect(isLeft(start, end, at(0, 50)), closeTo(0, 1e-18));
    });
  });

  group('退化した入力', () {
    test('頂点が2点しかなくても例外にはならない', () {
      // 呼び出し側(`evaluateEntryGuidanceRisk`)は3点未満を先に弾くが、
      // ここが例外を投げると評価ループごと落ちる。
      expect(isPointInPolygon(at(0, 0), [at(-10, 0), at(10, 0)]), isFalse);
    });

    test('空の区域は false', () {
      expect(isPointInPolygon(at(0, 0), const <LatLng>[]), isFalse);
    });
  });
}
