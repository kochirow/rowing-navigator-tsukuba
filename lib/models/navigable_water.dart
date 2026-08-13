import 'package:google_maps_flutter/google_maps_flutter.dart';

/// 表示・検証用の航路ポリゴン。初期版では安全判定に使わない。
class NavigableWater {
  final String id;
  final String name;
  final String kind;

  /// 往路(`outbound`)か復路(`return`)か。**表示専用。**
  ///
  /// 地図で往路・復路を塗り分けるためだけに使う。安全判定用の
  /// [ChannelLane] はこの値を一切見ない。表示の都合が安全判定へ
  /// 漏れない構造を保つこと。
  ///
  /// **`direction`(along / against)から往路・復路を導いてはいけない。**
  /// `direction` は「中心線の頂点の並び順に対してどちら向きか」という
  /// 安全判定の内部量であり、人間の呼び名とは無関係である。実データでも
  /// `lane_sakuragawa_estuary_outbound`(往路)は `direction: "against"` に
  /// なっている。id や name の文字列から推測するのも同じ理由で禁止で、
  /// 名前を変えた瞬間に色が静かに入れ替わる。
  ///
  /// 値が無い・不正なときは `null`。**例外にはしない。** 表示用の付加情報
  /// 1つで航路が1本まるごと消えるほうが害が大きい(原則1)。
  final String? leg;

  final List<LatLng> points;

  const NavigableWater({
    required this.id,
    required this.name,
    required this.kind,
    required this.points,
    this.leg,
  });

  factory NavigableWater.fromJson(Map<String, dynamic> map) {
    final id = map['id'];
    final name = map['name'];
    final kind = map['kind'];
    final rawPoints = map['points'];
    // 想定外の値は「向きが不明」として扱い、レーンそのものは残す。
    final rawLeg = map['leg'];
    final leg =
        (rawLeg == 'outbound' || rawLeg == 'return') ? rawLeg as String : null;
    if (id is! String ||
        id.isEmpty ||
        id.length > 128 ||
        name is! String ||
        kind is! String ||
        (kind != 'navigableWater' && kind != 'lane') ||
        rawPoints is! List ||
        rawPoints.length < 3 ||
        rawPoints.length > 1000) {
      throw const FormatException('Invalid navigable water');
    }
    final points = <LatLng>[];
    for (final raw in rawPoints) {
      if (raw is! Map || raw['lat'] is! num || raw['lng'] is! num) {
        throw const FormatException('Invalid navigable water point');
      }
      final lat = (raw['lat'] as num).toDouble();
      final lng = (raw['lng'] as num).toDouble();
      if (!lat.isFinite ||
          !lng.isFinite ||
          lat < -90 ||
          lat > 90 ||
          lng < -180 ||
          lng > 180) {
        throw const FormatException('Navigable water point is out of range');
      }
      points.add(LatLng(lat, lng));
    }
    return NavigableWater(
      id: id,
      name: name,
      kind: kind,
      leg: leg,
      points: List.unmodifiable(points),
    );
  }
}
