import 'package:google_maps_flutter/google_maps_flutter.dart';

/// 同梱プロファイルの桟橋エリア（着艇・係留の水域）。
///
/// **危険区域ではない。StaticObstacleへ変換・空間索引への登録をしてはならない。**
/// [AshoreArea] とも別物である。陸上エリアは「陸に上がった」という事実の判定で
/// **すべての音**を止めるが、桟橋エリアは水上の場所の宣言であり、
/// **自艇と相手の双方が低速のときの他艇警告の音**だけを落とす。
///
/// なぜ陸上エリアを広げないのか:
///
/// - 陸上判定は全ての音を止める。桟橋の沖側は水面であり、そこを通過する
///   他艇の警告まで消える。
/// - 陸上確定には30秒かかる。着艇の直前直後に空白ができる。
/// - 「陸上にいる」と「桟橋にいる」を混ぜると、どちらの理由で音が止まったのか
///   ログから読めなくなる。
class MooringArea {
  final String id;
  final String name;
  final List<LatLng> points;

  const MooringArea({
    required this.id,
    required this.name,
    required this.points,
  });

  factory MooringArea.fromJson(Map<String, dynamic> map) {
    final id = map['id'];
    final name = map['name'];
    final kind = map['kind'];
    final rawPoints = map['points'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 128 ||
        name is! String ||
        kind != 'mooringArea' ||
        rawPoints is! List ||
        rawPoints.length < 3 ||
        rawPoints.length > 1000) {
      throw const FormatException('Invalid mooring area');
    }
    final points = <LatLng>[];
    for (final raw in rawPoints) {
      if (raw is! Map || raw['lat'] is! num || raw['lng'] is! num) {
        throw const FormatException('Invalid mooring area point');
      }
      final lat = (raw['lat'] as num).toDouble();
      final lng = (raw['lng'] as num).toDouble();
      if (!lat.isFinite ||
          !lng.isFinite ||
          lat < -90 ||
          lat > 90 ||
          lng < -180 ||
          lng > 180) {
        throw const FormatException('Mooring area point is out of range');
      }
      points.add(LatLng(lat, lng));
    }
    return MooringArea(id: id, name: name, points: List.unmodifiable(points));
  }
}
