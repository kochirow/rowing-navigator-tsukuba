import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/services/swept_outline_service.dart';
import 'package:rowing_navigator/utils/geo_math.dart';
import 'package:rowing_navigator/utils/winding_algorithm.dart';

void main() {
  const origin = LatLng(36.069, 140.208);

  /// [origin] から東へ [eastMeters]、北へ [northMeters] 移動した地点。
  LatLng offset(double eastMeters, double northMeters) {
    final movedNorth = computeOffset(origin, northMeters, 0);
    return computeOffset(movedNorth, eastMeters, 90);
  }

  /// 一辺 [sideMeters] の正方形を、東へ [eastMeters] ずらして作る。
  List<LatLng> square(double sideMeters, {double eastMeters = 0}) => [
        offset(eastMeters, 0),
        offset(eastMeters + sideMeters, 0),
        offset(eastMeters + sideMeters, sideMeters),
        offset(eastMeters, sideMeters),
      ];

  test('正方形1枚なら頂点4つがそのまま返る', () {
    final outline = sweptOutline([square(10)]);

    expect(outline.length, 4);
    for (final vertex in square(10)) {
      expect(
        outline.any(
            (point) => distanceMeters(point, vertex) < 0.05), // 投影の丸めぶんだけ許容
        isTrue,
        reason: '入力の頂点 $vertex が外形に残っていない',
      );
    }
  });

  test('東へ10mずつずらした5枚の外形は、全入力頂点を含む', () {
    final polygons = [
      for (var index = 0; index < 5; index++)
        square(6, eastMeters: index * 10.0),
    ];

    final outline = sweptOutline(polygons);

    expect(outline.length, greaterThanOrEqualTo(4));
    for (final polygon in polygons) {
      for (final vertex in polygon) {
        // 境界上の頂点は isPointInPolygon が false を返しうるため、
        // 「内側」と「外形の頂点と一致」のどちらかで判定する。
        final onOutline =
            outline.any((point) => distanceMeters(point, vertex) < 0.05);
        expect(
          onOutline || isPointInPolygon(vertex, outline),
          isTrue,
          reason: '入力頂点 $vertex が外形の外に出ている',
        );
      }
    }
  });

  test('外形は入力より小さくならない(掃引の届く先を削らない)', () {
    final polygons = [
      for (var index = 0; index < 5; index++)
        square(6, eastMeters: index * 10.0),
    ];

    final outline = sweptOutline(polygons);
    final easternmost = polygons.last[1]; // 東端の頂点
    expect(
      outline.map((point) => point.longitude).reduce((a, b) => a > b ? a : b),
      greaterThanOrEqualTo(easternmost.longitude - 1e-9),
    );
  });

  group('縮退した入力でも例外を投げない', () {
    test('空リスト → 空リスト', () {
      expect(sweptOutline(const []), isEmpty);
      expect(sweptOutline([const []]), isEmpty);
    });

    test('1点だけ → そのまま返す', () {
      final outline = sweptOutline([
        [origin]
      ]);
      expect(outline, [origin]);
    });

    test('2点だけ → そのまま返す', () {
      final points = [origin, offset(5, 0)];
      expect(sweptOutline([points]).length, 2);
    });

    test('全点が一直線上 → 端点だけが残る', () {
      // 同じ緯度で経度だけを変え、厳密に一直線になる点列を作る。
      // computeOffset は大圏に沿うため、東へ進めると緯度がごく僅かに
      // 動き、厳密な一直線にはならない。
      const line = [
        LatLng(36.069, 140.2080),
        LatLng(36.069, 140.2081),
        LatLng(36.069, 140.2082),
        LatLng(36.069, 140.2083),
      ];

      final outline = sweptOutline([line]);

      expect(outline.length, 2);
      final longitudes = outline.map((point) => point.longitude).toList()
        ..sort();
      expect(longitudes.first, closeTo(140.2080, 1e-6));
      expect(longitudes.last, closeTo(140.2083, 1e-6));
    });

    test('全点が同じ位置 → 1点に潰れる', () {
      final outline = sweptOutline([
        [origin, origin, origin],
      ]);
      expect(outline.length, 1);
    });

    test('非有限な座標は捨てる', () {
      final outline = sweptOutline([
        [...square(10), const LatLng(double.nan, double.nan)],
      ]);
      expect(outline.length, 4);
      for (final point in outline) {
        expect(point.latitude.isFinite, isTrue);
        expect(point.longitude.isFinite, isTrue);
      }
    });
  });
}
