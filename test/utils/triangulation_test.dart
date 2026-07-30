import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/utils/triangulation.dart';
import 'package:vector_math/vector_math.dart';

/// `PolygonTriangulation` は `polygonsOverlap` の前段。凹んだ危険区域を
/// 凸な三角形へ分けてからSATに渡す。ここが落ちる・面積を取りこぼすと、
/// 凹部の重なり判定がそのまま狂う。
double triangleArea(List<Vector2> triangle) =>
    ((triangle[1] - triangle[0]).cross(triangle[2] - triangle[0])).abs() / 2;

double totalArea(List<List<Vector2>> triangles) =>
    triangles.fold<double>(0, (sum, triangle) => sum + triangleArea(triangle));

void main() {
  final triangulation = PolygonTriangulation();

  group('三角形分割', () {
    test('凸な正方形は2つの三角形になり、面積が保存される', () {
      final square = [
        Vector2(0, 0),
        Vector2(4, 0),
        Vector2(4, 4),
        Vector2(0, 4),
      ];

      final triangles = triangulation.triangulate(square);

      expect(triangles, hasLength(2));
      expect(totalArea(triangles), closeTo(16.0, 1e-9));
    });

    test('凹んだL字は n−2 個の三角形になり、面積が保存される', () {
      // (0,0)-(4,0)-(4,2)-(2,2)-(2,4)-(0,4)。面積 = 8 + 4 = 12。
      final lShape = [
        Vector2(0, 0),
        Vector2(4, 0),
        Vector2(4, 2),
        Vector2(2, 2),
        Vector2(2, 4),
        Vector2(0, 4),
      ];

      final triangles = triangulation.triangulate(lShape);

      expect(triangles, hasLength(lShape.length - 2));
      expect(totalArea(triangles), closeTo(12.0, 1e-9));
    });

    test('時計回りで与えても反時計回りへ正規化して同じ結果になる', () {
      final ccw = [
        Vector2(0, 0),
        Vector2(4, 0),
        Vector2(4, 2),
        Vector2(2, 2),
        Vector2(2, 4),
        Vector2(0, 4),
      ];
      final cw = ccw.reversed.toList();

      expect(totalArea(triangulation.triangulate(cw)),
          closeTo(totalArea(triangulation.triangulate(ccw)), 1e-9));
      expect(triangulation.triangulate(cw), hasLength(4));
    });

    test('ensureCounterClockwise は向きだけを揃える', () {
      final cw = [
        Vector2(0, 0),
        Vector2(0, 4),
        Vector2(4, 4),
        Vector2(4, 0),
      ];

      final normalized = triangulation.ensureCounterClockwise(cw);

      expect(normalized, hasLength(cw.length));
      expect(normalized.toSet(), cw.toSet());
      // 反時計回りなら符号付き面積は正。
      var sum = 0.0;
      for (var i = 0; i < normalized.length; i++) {
        final current = normalized[i];
        final next = normalized[(i + 1) % normalized.length];
        sum += current.cross(next);
      }
      expect(sum / 2, greaterThan(0));
    });

    test('細長い区域(岸の基準線から作る長方形)でも分割できる', () {
      // 岸は基準線の各辺を長方形へ展開したもの。極端な縦横比で落ちない。
      final sliver = [
        Vector2(0, 0),
        Vector2(200, 0),
        Vector2(200, 0.5),
        Vector2(0, 0.5),
      ];

      final triangles = triangulation.triangulate(sliver);

      expect(triangles, hasLength(2));
      expect(totalArea(triangles), closeTo(100.0, 1e-6));
    });
  });

  group('退化した入力', () {
    test('頂点が3点に満たなければ例外', () {
      expect(
        () => triangulation.triangulate([Vector2(0, 0), Vector2(1, 1)]),
        throwsException,
      );
    });

    test('全点が共線なら例外(耳が見つからない)', () {
      expect(
        () => triangulation.triangulate([
          Vector2(0, 0),
          Vector2(1, 0),
          Vector2(2, 0),
          Vector2(3, 0),
        ]),
        throwsException,
      );
    });

    test('自己交差(蝶ネクタイ)は例外にならず、三角形を返す', () {
      // 例外を投げないことを固定しておく。呼び出し側(`polygonsOverlap`)は
      // この結果をそのままSATへ渡し、外れる向きは警告を増やす側になる。
      final bowtie = [
        Vector2(0, 0),
        Vector2(10, 0),
        Vector2(0, 10),
        Vector2(10, 10),
      ];

      final triangles = triangulation.triangulate(bowtie);

      expect(triangles, hasLength(2));
    });
  });

  group('isPointInTriangle', () {
    final a = Vector2(0, 0);
    final b = Vector2(4, 0);
    final c = Vector2(0, 4);

    test('内部の点は true', () {
      expect(triangulation.isPointInTriangle(Vector2(1, 1), a, b, c), isTrue);
    });

    test('外部の点は false', () {
      expect(triangulation.isPointInTriangle(Vector2(5, 5), a, b, c), isFalse);
      expect(triangulation.isPointInTriangle(Vector2(-1, 1), a, b, c), isFalse);
    });

    test('頂点は内側として扱う', () {
      expect(triangulation.isPointInTriangle(a, a, b, c), isTrue);
    });
  });
}
