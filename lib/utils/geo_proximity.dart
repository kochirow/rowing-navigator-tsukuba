import 'dart:math';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'winding_algorithm.dart';

const double _earthRadius = 6378137.0; // 地球の半径 [m]

/// 点からポリゴン(危険区域など)までの最短距離 [m] を返す。
/// 点がポリゴンの内部にある場合は 0 を返す。
///
/// 安全側の設計として、頂点数が不足する「不正な」ポリゴンでも
/// 判定対象外(無限大)にはせず、可能な範囲で距離を返す:
/// - 頂点1点: その点までの距離
/// - 頂点2点: その線分までの距離
/// - 頂点0点: 判定不能のため無限大
///
/// 数百m程度の近距離を対象とした簡易計算(正距円筒近似)のため、
/// 長距離の計算には使用しないこと。
double minDistanceToPolygonMeters(LatLng point, List<LatLng> polygon) {
  if (polygon.isEmpty) return double.infinity;

  final lat0 = point.latitude * pi / 180.0;
  // 対象点を原点とするローカル平面座標 [m] に変換
  double toX(LatLng p) =>
      (p.longitude - point.longitude) * pi / 180.0 * cos(lat0) * _earthRadius;
  double toY(LatLng p) =>
      (p.latitude - point.latitude) * pi / 180.0 * _earthRadius;

  if (polygon.length == 1) {
    final x = toX(polygon[0]);
    final y = toY(polygon[0]);
    return sqrt(x * x + y * y);
  }

  if (isPointInPolygon(point, polygon)) return 0.0;

  double minDist = double.infinity;
  final edgeCount = polygon.length == 2 ? 1 : polygon.length;
  for (int i = 0; i < edgeCount; i++) {
    final a = polygon[i];
    final b = polygon[(i + 1) % polygon.length];
    final d = _distancePointToSegment(0.0, 0.0, toX(a), toY(a), toX(b), toY(b));
    if (d < minDist) minDist = d;
  }
  return minDist;
}

/// 点からポリゴンまでの符号付き最短距離 [m]。内部は負、外部は正。
///
/// [minDistanceToPolygonMeters] は内部を一律0に潰すため、区域へ入り込んだ
/// あとは「さらに何m入ったか」が分からない。安定停止中の再接近検出や
/// 警告の優先順位付けでは単調な指標が要るので、内部では最寄りの辺までの
/// 距離を負値で返す。
double signedDistanceToPolygonMeters(LatLng point, List<LatLng> polygon) {
  if (polygon.isEmpty) return double.infinity;
  final inside = polygon.length >= 3 && isPointInPolygon(point, polygon);
  final edgeDistance = _distanceToPolygonEdgesMeters(point, polygon);
  return inside ? -edgeDistance : edgeDistance;
}

/// ポリゴンの内外を問わず、最も近い辺までの距離 [m]。
double _distanceToPolygonEdgesMeters(LatLng point, List<LatLng> polygon) {
  final lat0 = point.latitude * pi / 180.0;
  double toX(LatLng p) =>
      (p.longitude - point.longitude) * pi / 180.0 * cos(lat0) * _earthRadius;
  double toY(LatLng p) =>
      (p.latitude - point.latitude) * pi / 180.0 * _earthRadius;

  if (polygon.length == 1) {
    final x = toX(polygon[0]);
    final y = toY(polygon[0]);
    return sqrt(x * x + y * y);
  }

  double minDist = double.infinity;
  final edgeCount = polygon.length == 2 ? 1 : polygon.length;
  for (int i = 0; i < edgeCount; i++) {
    final a = polygon[i];
    final b = polygon[(i + 1) % polygon.length];
    final d = _distancePointToSegment(0.0, 0.0, toX(a), toY(a), toX(b), toY(b));
    if (d < minDist) minDist = d;
  }
  return minDist;
}

/// ポリゴン境界上で [point] に最も近い地点を返す。
///
/// 警告の方向(「右」「左後方」)を示すために使う。岸の危険区域は基準線の各辺を
/// 長方形へ展開したものなので、重心方向は「どちら側に岸があるか」とほぼ無関係。
/// 最寄りの辺上の点を使わないと、真横の岸が「後方」と案内されうる。
/// 頂点が無い場合だけ null を返す。
LatLng? nearestPointOnPolygon(LatLng point, List<LatLng> polygon) {
  if (polygon.isEmpty) return null;
  if (polygon.length == 1) return polygon.first;

  final lat0 = point.latitude * pi / 180.0;
  final cosLat = cos(lat0);
  double toX(LatLng p) =>
      (p.longitude - point.longitude) * pi / 180.0 * cosLat * _earthRadius;
  double toY(LatLng p) =>
      (p.latitude - point.latitude) * pi / 180.0 * _earthRadius;

  var bestDistance = double.infinity;
  var bestX = 0.0;
  var bestY = 0.0;
  final edgeCount = polygon.length == 2 ? 1 : polygon.length;
  for (var i = 0; i < edgeCount; i++) {
    final a = polygon[i];
    final b = polygon[(i + 1) % polygon.length];
    final ax = toX(a);
    final ay = toY(a);
    final dx = toX(b) - ax;
    final dy = toY(b) - ay;
    final lengthSquared = dx * dx + dy * dy;
    final t = lengthSquared == 0
        ? 0.0
        : (((0.0 - ax) * dx + (0.0 - ay) * dy) / lengthSquared).clamp(0.0, 1.0);
    final cx = ax + t * dx;
    final cy = ay + t * dy;
    final distance = cx * cx + cy * cy;
    if (distance < bestDistance) {
      bestDistance = distance;
      bestX = cx;
      bestY = cy;
    }
  }
  if (!bestDistance.isFinite) return null;
  if (cosLat == 0) return null;
  return LatLng(
    point.latitude + bestY / _earthRadius * 180.0 / pi,
    point.longitude + bestX / (_earthRadius * cosLat) * 180.0 / pi,
  );
}

/// 点(px, py)から線分(ax, ay)-(bx, by)までの最短距離
double _distancePointToSegment(
    double px, double py, double ax, double ay, double bx, double by) {
  final dx = bx - ax;
  final dy = by - ay;
  final lenSq = dx * dx + dy * dy;
  double t = lenSq == 0 ? 0.0 : ((px - ax) * dx + (py - ay) * dy) / lenSq;
  t = t.clamp(0.0, 1.0);
  final cx = ax + t * dx;
  final cy = ay + t * dy;
  return sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
}
