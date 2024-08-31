import 'package:vector_math/vector_math.dart';

class PolygonTriangulation {
  // 順序が時計回りか反時計回りかを確認し、反時計回りでなければ反転する
  List<Vector2> ensureCounterClockwise(List<Vector2> polygon) {
    double sum = 0;
    for (int i = 0; i < polygon.length; i++) {
      Vector2 current = polygon[i];
      Vector2 next = polygon[(i + 1) % polygon.length];
      sum += (next.x - current.x) * (next.y + current.y); // 多角形の符号付き面積を計算
    }
    if (sum > 0) {
      return polygon.reversed.toList();
    }
    return polygon;
  }

  // 頂点が三角形の内部にあるかどうかを判定する関数／バリツェリアン座標系を使用
  bool isPointInTriangle(Vector2 p, Vector2 a, Vector2 b, Vector2 c) {
    var v0 = c - a;
    var v1 = b - a;
    var v2 = p - a;

    var dot00 = v0.dot(v0);
    var dot01 = v0.dot(v1);
    var dot02 = v0.dot(v2);
    var dot11 = v1.dot(v1);
    var dot12 = v1.dot(v2);

    var invDenom = 1 / (dot00 * dot11 - dot01 * dot01);
    var u = (dot11 * dot02 - dot01 * dot12) * invDenom;
    var v = (dot00 * dot12 - dot01 * dot02) * invDenom;

    return (u >= 0) && (v >= 0) && (u + v < 1);
  }

  // 頂点が耳であるかどうかを判定する関数
  bool isEar(List<Vector2> polygon, int i) {
    int prev = (i - 1 + polygon.length) % polygon.length;
    int next = (i + 1) % polygon.length;

    Vector2 a = polygon[prev];
    Vector2 b = polygon[i];
    Vector2 c = polygon[next];

    if (((b - a).cross(c - b)) <= 0) {
      return false; // Concave vertex or collinear
    }

    for (int j = 0; j < polygon.length; j++) {
      if (j == prev || j == i || j == next) continue;
      if (isPointInTriangle(polygon[j], a, b, c)) return false;
    }
    return true;
  }

  // ポリゴンを三角形に分割する関数
  List<List<Vector2>> triangulate(List<Vector2> polygon) {
    if (polygon.length < 3) {
      throw Exception("Polygon must have at least 3 vertices.");
    }
    polygon = ensureCounterClockwise(polygon); // 順序を確認し、必要に応じて反転する

    List<List<Vector2>> triangles = [];
    List<Vector2> remainingPolygon = List.from(polygon);

    while (remainingPolygon.length > 3) {
      bool earFound = false;

      for (int i = 0; i < remainingPolygon.length; i++) {
        if (isEar(remainingPolygon, i)) {
          int prev =
              (i - 1 + remainingPolygon.length) % remainingPolygon.length;
          int next = (i + 1) % remainingPolygon.length;

          Vector2 a = remainingPolygon[prev];
          Vector2 b = remainingPolygon[i];
          Vector2 c = remainingPolygon[next];

          triangles.add([a, b, c]); // 三角形を切り出し

          remainingPolygon.removeAt(i); // 三角形を切り出し
          earFound = true;
          break;
        }
      }

      // 必ず耳はあるはずなので、耳が見つからない場合はポリゴンが不正である／自己交差がある場合はエラー
      if (!earFound) {
        throw Exception("No ear found. The polygon might be degenerate.");
      }
    }

    triangles
        .add([remainingPolygon[0], remainingPolygon[1], remainingPolygon[2]]);
    return triangles;
  }
}
