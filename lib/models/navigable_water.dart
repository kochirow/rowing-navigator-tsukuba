import 'package:google_maps_flutter/google_maps_flutter.dart';

/// 表示・検証用の航路ポリゴン。初期版では安全判定に使わない。
class NavigableWater {
  final String id;
  final String name;
  final String kind;
  final List<LatLng> points;

  const NavigableWater({
    required this.id,
    required this.name,
    required this.kind,
    required this.points,
  });

  factory NavigableWater.fromJson(Map<String, dynamic> map) {
    final id = map['id'];
    final name = map['name'];
    final kind = map['kind'];
    final rawPoints = map['points'];
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
      points: List.unmodifiable(points),
    );
  }
}
