import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../services/record/replay_track.dart';

/// 本・区間の向き（表示専用）。川では「上り/下り」、霞ヶ浦では「沖へ/戻り」。
///
/// 河口（桜川河口の中心線のうち、霞ヶ浦の中心線に近い端）までの距離が、
/// 本の始まりより終わりで縮んでいれば下り（湖では戻り）。差が80m未満なら「往復」。
/// 中心線が読めなければ向きは出さない（縮退）。
class BoutDirectionResolver {
  final LatLng? _mouth;
  final List<({String id, List<LatLng> points})> _lines;

  static const estuaryId = 'centerline_sakuragawa_estuary';
  static const lakeId = 'centerline_kasumikagaura';

  BoutDirectionResolver._(this._mouth, this._lines);

  factory BoutDirectionResolver(Map<String, List<LatLng>> centerlines) {
    final estuary = centerlines[estuaryId];
    final lake = centerlines[lakeId];
    LatLng? mouth;
    if (estuary != null &&
        estuary.length >= 2 &&
        lake != null &&
        lake.isNotEmpty) {
      final a = estuary.first, b = estuary.last, l = lake.first;
      mouth = _dist(a, l) < _dist(b, l) ? a : b;
    }
    return BoutDirectionResolver._(mouth, [
      for (final e in centerlines.entries) (id: e.key, points: e.value),
    ]);
  }

  String? directionOf(ReplayTrack track, ReplayRange range) {
    final mouth = _mouth;
    if (mouth == null || track.isEmpty) return null;
    final a = track.positionAt(range.start), b = track.positionAt(range.end);
    final m = track.positionAt((range.start + range.end) / 2);
    final da = _dist(LatLng(a.lat, a.lng), mouth);
    final db = _dist(LatLng(b.lat, b.lng), mouth);
    if ((da - db).abs() < 80) return '往復';
    final onLake = _nearestLine(LatLng(m.lat, m.lng)) == lakeId;
    if (onLake) return db < da ? '戻り' : '沖へ';
    return db < da ? '下り' : '上り';
  }

  String? _nearestLine(LatLng p) {
    String? best;
    var bestD = double.infinity;
    for (final l in _lines) {
      for (final q in l.points) {
        final d = _dist(p, q);
        if (d < bestD) {
          bestD = d;
          best = l.id;
        }
      }
    }
    return best;
  }

  static double _dist(LatLng a, LatLng b) {
    const r = 6371000.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final h = math.pow(math.sin(dLat / 2), 2) +
        math.cos(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            math.pow(math.sin(dLng / 2), 2);
    return 2 * r * math.asin(math.sqrt(h));
  }
}
