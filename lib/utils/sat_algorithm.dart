import 'dart:math' as math;
import 'package:vector_math/vector_math.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'triangulation.dart';

// 経度緯度で表される2つのポリゴンが重なっているかどうかを判定する
bool polygonsOverlap(Polygon polygon1, Polygon polygon2) {
  List<LatLng> points1 = polygon1.points;
  List<LatLng> points2 = polygon2.points;
  // LatLngをVector2に変換
  List<Vector2> polygon1Vectors =
      points1.map((point) => Vector2(point.latitude, point.longitude)).toList();
  List<Vector2> polygon2Vectors =
      points2.map((point) => Vector2(point.latitude, point.longitude)).toList();

  // 凹多角形に対応するため、ポリゴンを三角形に分割する
  PolygonTriangulation triangulation = PolygonTriangulation();
  List<List<Vector2>> triangles1 = triangulation.triangulate(polygon1Vectors);
  List<List<Vector2>> triangles2 = triangulation.triangulate(polygon2Vectors);

  // 2つのポリゴンの三角形同士が重なっているかどうかを判定する
  for (var triangle1 in triangles1) {
    for (var triangle2 in triangles2) {
      if (checkPolygonsOverlap(triangle1, triangle2)) {
        return true;
      }
    }
  }
  return false;
}

// 2つのポリゴンが重なっているかどうかを判定する
bool checkPolygonsOverlap(List<Vector2> polygon1, List<Vector2> polygon2) {
  for (var polygon in [polygon1, polygon2]) {
    for (var i = 0; i < polygon.length; i++) {
      var edge = polygon[(i + 1) % polygon.length] - polygon[i]; // エッジベクトル
      var axis = Vector2(-edge.y, edge.x); // エッジベクトルに対する法線ベクトル

      // 頂点を法線ベクトルに射影し、その最小値と最大値を取得
      var proj1 = projectPolygon(polygon1, axis);
      var proj2 = projectPolygon(polygon2, axis);

      // 射影した値が重なっていない場合は、ポリゴンは重なっていない
      if (proj1[1] < proj2[0] || proj2[1] < proj1[0]) {
        return false;
      }
    }
  }
  return true;
}

// 指定した軸にポリゴンを射影したときの最小値と最大値を返す
List<double> projectPolygon(List<Vector2> polygon, Vector2 axis) {
  var min = double.infinity;
  var max = double.negativeInfinity;
  for (var vertex in polygon) {
    var projection = vertex.dot(axis); // 頂点ベクトルと軸ベクトルの内積を取ると射影された値が得られる
    min = math.min(min, projection);
    max = math.max(max, projection);
  }
  return [min, max];
}
