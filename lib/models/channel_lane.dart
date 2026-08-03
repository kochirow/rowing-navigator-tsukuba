import 'package:google_maps_flutter/google_maps_flutter.dart';

/// 航路中心線の頂点順に対する、レーンの規定進行方向。
enum LaneDirection { along, against }

/// 安全判定に使う、向きが検証済みの航路レーン。
///
/// [NavigableWater] は地図表示・作図検証用のまま残す。安全経路へ渡す
/// データは、この専用型で `kind` と `direction` を検証してから扱う。
class ChannelLane {
  final String id;
  final String name;
  final LaneDirection direction;
  final String? centerlineId;
  final List<LatLng> points;

  const ChannelLane({
    required this.id,
    required this.name,
    required this.direction,
    this.centerlineId,
    required this.points,
  });

  factory ChannelLane.fromJson(Map<String, dynamic> map) {
    final id = map['id'];
    final name = map['name'];
    final kind = map['kind'];
    final rawDirection = map['direction'];
    final rawCenterlineId = map['centerlineId'];
    final rawPoints = map['points'];
    final direction = switch (rawDirection) {
      'along' => LaneDirection.along,
      'against' => LaneDirection.against,
      _ => null,
    };
    if (id is! String ||
        id.isEmpty ||
        id.length > 128 ||
        name is! String ||
        kind != 'lane' ||
        direction == null ||
        (rawCenterlineId != null &&
            (rawCenterlineId is! String ||
                rawCenterlineId.isEmpty ||
                rawCenterlineId.length > 128)) ||
        rawPoints is! List ||
        rawPoints.length < 3 ||
        rawPoints.length > 1000) {
      throw const FormatException('Invalid channel lane');
    }

    final points = <LatLng>[];
    for (final raw in rawPoints) {
      if (raw is! Map || raw['lat'] is! num || raw['lng'] is! num) {
        throw const FormatException('Invalid channel lane point');
      }
      final lat = (raw['lat'] as num).toDouble();
      final lng = (raw['lng'] as num).toDouble();
      if (!lat.isFinite ||
          !lng.isFinite ||
          lat < -90 ||
          lat > 90 ||
          lng < -180 ||
          lng > 180) {
        throw const FormatException('Channel lane point is out of range');
      }
      points.add(LatLng(lat, lng));
    }

    return ChannelLane(
      id: id,
      name: name,
      direction: direction,
      centerlineId: rawCenterlineId as String?,
      points: List.unmodifiable(points),
    );
  }
}
