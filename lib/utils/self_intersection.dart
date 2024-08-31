import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:math' as math;

// 2つの線分が交差しているかどうかをチェックする関数
bool doLinesIntersect(LatLng p1, LatLng p2, LatLng q1, LatLng q2) {
  double crossProduct(LatLng a, LatLng b, LatLng c) {
    return (b.latitude - a.latitude) * (c.longitude - a.longitude) -
        (b.longitude - a.longitude) * (c.latitude - a.latitude);
  }

  bool onSegment(LatLng p, LatLng q, LatLng r) {
    if (q.longitude <= math.max(p.longitude, r.longitude) &&
        q.longitude >= math.min(p.longitude, r.longitude) &&
        q.latitude <= math.max(p.latitude, r.latitude) &&
        q.latitude >= math.min(p.latitude, r.latitude)) {
      return true;
    }
    return false;
  }

  double d1 = crossProduct(p1, p2, q1);
  double d2 = crossProduct(p1, p2, q2);
  double d3 = crossProduct(q1, q2, p1);
  double d4 = crossProduct(q1, q2, p2);

  if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
      ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))) {
    return true;
  }

  if (d1 == 0 && onSegment(p1, q1, p2)) return true;
  if (d2 == 0 && onSegment(p1, q2, p2)) return true;
  if (d3 == 0 && onSegment(q1, p1, q2)) return true;
  if (d4 == 0 && onSegment(q1, p2, q2)) return true;

  return false;
}

// ポリゴンが自己交差しているかどうかをチェックする関数
bool isSelfIntersecting(List<LatLng> polygon) {
  int n = polygon.length;
  if (n < 4) return false; // 最低でも4つの頂点が必要

  for (int i = 0; i < n; i++) {
    for (int j = i + 2; j < n; j++) {
      // 隣接する辺は無視する
      if (i == 0 && j == n - 1) continue;

      if (doLinesIntersect(
          polygon[i], polygon[(i + 1) % n], polygon[j], polygon[(j + 1) % n])) {
        return true;
      }
    }
  }
  return false;
}
