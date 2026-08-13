/// 掃引した予測領域の外形を1枚のポリゴンへまとめる、表示専用のサービス。
///
/// **安全判定はここを使わない。** 判定はサンプルごとの連続SAT
/// (`ContinuousCollisionService`)で行っており、この外形は地図に線を引く
/// ためだけのものである。判定の入力にしてはいけない。
///
/// 1艇の予測帯は、これまで最大24サンプル × 2枚 = 最大48枚のポリゴンを
/// 重ねて描いていた。中身は同じ六角形の平行移動の繰り返しなので、
/// 情報量は増えないまま画面だけが埋まる。zoom 19 では 50m の掃引帯が
/// 画面縦の約半分を覆うため、外形1枚へまとめる。
///
/// 純Dart。Flutter には依存しない(LatLng を除く)。
library;

import 'dart:math';

import 'package:google_maps_flutter/google_maps_flutter.dart';

const _earthRadiusMeters = 6378137.0;

/// [polygons] の全頂点を包む凸包を返す。
///
/// 川なり予測(曲線)のときは、凸包が内カーブ側をわずかに外へ膨らませる
/// (50m掃引・半径200mで約1.5m)。線で描く予測の外形としては許容できる
/// 誤差である。**この膨らみを安全判定へ持ち込まないこと。**
///
/// 縮退した入力でも例外を投げない(原則1: 表示のために航行を止めない)。
/// - 空 → 空
/// - 有効な頂点が3点未満 → 集めた頂点をそのまま返す
/// - 全点が一直線上 → その線分の端点を返す
List<LatLng> sweptOutline(List<List<LatLng>> polygons) {
  final points = <LatLng>[];
  for (final polygon in polygons) {
    for (final point in polygon) {
      if (point.latitude.isFinite && point.longitude.isFinite) {
        points.add(point);
      }
    }
  }
  if (points.length < 3) return List<LatLng>.unmodifiable(points);

  // 平均緯度経度を原点にしたメートル平面で解く。緯度経度のまま外積を
  // 取ると、経度1度の実距離が緯度で変わるぶん凸判定が歪む。
  final origin = LatLng(
    points.map((point) => point.latitude).reduce((a, b) => a + b) /
        points.length,
    points.map((point) => point.longitude).reduce((a, b) => a + b) /
        points.length,
  );
  final local = points.map((point) => _toLocal(origin, point)).toList()
    // Monotone Chain(Andrew's algorithm)は x, y の辞書順ソートが前提。
    ..sort((a, b) => a.x == b.x ? a.y.compareTo(b.y) : a.x.compareTo(b.x));
  // 停止中の艇は全サンプルが同じ位置になる。重複を残すと外積が常に0で、
  // 殻の構築が「同じ点2つ」を返してしまう。先に潰しておく。
  final deduplicated = <_Point>[];
  for (final point in local) {
    final last = deduplicated.isEmpty ? null : deduplicated.last;
    if (last != null && last.x == point.x && last.y == point.y) continue;
    deduplicated.add(point);
  }

  final hull = _monotoneChain(deduplicated);
  if (hull.length < 3) {
    // 全点が一直線・全点が同一。凸包が面を持たないので、そのまま返す。
    return List<LatLng>.unmodifiable(
      hull.map((point) => _fromLocal(origin, point)),
    );
  }
  return List<LatLng>.unmodifiable(
    hull.map((point) => _fromLocal(origin, point)),
  );
}

/// ソート済みの点列から凸包を作る。反時計回りで返す。
List<_Point> _monotoneChain(List<_Point> sorted) {
  final lower = <_Point>[];
  for (final point in sorted) {
    // 外積が0以下の点は凸包の内側か辺上なので捨てる。
    while (lower.length >= 2 &&
        _cross(lower[lower.length - 2], lower.last, point) <= 0) {
      lower.removeLast();
    }
    lower.add(point);
  }
  final upper = <_Point>[];
  for (final point in sorted.reversed) {
    while (upper.length >= 2 &&
        _cross(upper[upper.length - 2], upper.last, point) <= 0) {
      upper.removeLast();
    }
    upper.add(point);
  }
  if (lower.length <= 1) return lower;
  // 端点は上下の殻で重複するため、それぞれ末尾を落として連結する。
  return [
    ...lower.sublist(0, lower.length - 1),
    ...upper.sublist(0, upper.length - 1),
  ];
}

double _cross(_Point origin, _Point a, _Point b) =>
    (a.x - origin.x) * (b.y - origin.y) - (a.y - origin.y) * (b.x - origin.x);

_Point _toLocal(LatLng origin, LatLng point) {
  final meanLatitude = (origin.latitude + point.latitude) / 2 * pi / 180;
  return _Point(
    (point.longitude - origin.longitude) *
        pi /
        180 *
        cos(meanLatitude) *
        _earthRadiusMeters,
    (point.latitude - origin.latitude) * pi / 180 * _earthRadiusMeters,
  );
}

LatLng _fromLocal(LatLng origin, _Point point) {
  final latitude = origin.latitude + point.y / _earthRadiusMeters * 180 / pi;
  final longitude = origin.longitude +
      point.x /
          (_earthRadiusMeters * cos(origin.latitude * pi / 180)) *
          180 /
          pi;
  return LatLng(latitude, longitude);
}

class _Point {
  final double x;
  final double y;

  const _Point(this.x, this.y);
}
