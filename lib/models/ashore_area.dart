import 'package:google_maps_flutter/google_maps_flutter.dart';

/// 同梱プロファイルの陸上エリア（警告停止エリア）。
///
/// 危険区域ではない。StaticObstacleへ変換・空間索引への登録をしてはならない。
class AshoreArea {
  final String id;
  final String name;
  final List<LatLng> points;

  const AshoreArea({
    required this.id,
    required this.name,
    required this.points,
  });

  factory AshoreArea.fromJson(Map<String, dynamic> map) {
    final id = map['id'];
    final name = map['name'];
    final kind = map['kind'];
    final rawPoints = map['points'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 128 ||
        name is! String ||
        kind != 'ashoreArea' ||
        rawPoints is! List ||
        rawPoints.length < 3 ||
        rawPoints.length > 1000) {
      throw const FormatException('Invalid ashore area');
    }
    final points = <LatLng>[];
    for (final raw in rawPoints) {
      if (raw is! Map || raw['lat'] is! num || raw['lng'] is! num) {
        throw const FormatException('Invalid ashore area point');
      }
      final lat = (raw['lat'] as num).toDouble();
      final lng = (raw['lng'] as num).toDouble();
      if (!lat.isFinite ||
          !lng.isFinite ||
          lat < -90 ||
          lat > 90 ||
          lng < -180 ||
          lng > 180) {
        throw const FormatException('Ashore area point is out of range');
      }
      points.add(LatLng(lat, lng));
    }
    return AshoreArea(id: id, name: name, points: List.unmodifiable(points));
  }
}
