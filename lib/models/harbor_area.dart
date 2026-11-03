import 'package:google_maps_flutter/google_maps_flutter.dart';

/// 同梱プロファイルの「港の中」(発着場所から航路の入口までの水面)。
///
/// **危険区域ではない。StaticObstacleへ変換・空間索引への登録をしてはならない。**
/// 桟橋エリア([MooringArea])と同じく、水上の場所の宣言である。中にいる間だけ、
/// 岸の警告の鳴り始めを停止時間＋1秒へ縮めて1回だけにし、自艇と相手がともに
/// 低速なら他艇の警告を1回だけにする。逆走注意は鳴らさない。検知・表示・記録・
/// 位置共有は変えない。
///
/// 桟橋エリアとの違い: 桟橋エリアは「着艇して並んでいる」場所で、両者が止まって
/// いれば他艇の音を止める。港の中は、桟橋から防波堤の先まで艇を出し入れする
/// 水面全体で、音は止めずに控えめにする。
class HarborArea {
  final String id;
  final String name;
  final List<LatLng> points;

  const HarborArea({
    required this.id,
    required this.name,
    required this.points,
  });

  factory HarborArea.fromJson(Map<String, dynamic> map) {
    final id = map['id'];
    final name = map['name'];
    final kind = map['kind'];
    final rawPoints = map['points'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 128 ||
        name is! String ||
        kind != 'harborArea' ||
        rawPoints is! List ||
        rawPoints.length < 3 ||
        rawPoints.length > 1000) {
      throw const FormatException('Invalid harbor area');
    }
    final points = <LatLng>[];
    for (final raw in rawPoints) {
      if (raw is! Map || raw['lat'] is! num || raw['lng'] is! num) {
        throw const FormatException('Invalid harbor area point');
      }
      final lat = (raw['lat'] as num).toDouble();
      final lng = (raw['lng'] as num).toDouble();
      if (!lat.isFinite ||
          !lng.isFinite ||
          lat < -90 ||
          lat > 90 ||
          lng < -180 ||
          lng > 180) {
        throw const FormatException('Harbor area point is out of range');
      }
      points.add(LatLng(lat, lng));
    }
    return HarborArea(id: id, name: name, points: List.unmodifiable(points));
  }
}
