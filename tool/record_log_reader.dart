// 実機の診断パッケージ（track.csv）を記録の点へ読み込む。記録画面の検証ツール用。
// 診断パッケージは個人の航跡を含むためリポジトリには入れない。

import 'dart:io';

import 'package:rowing_navigator/models/session_model.dart';

List<TrackPoint> readTrack(String dir) {
  final lines = File('$dir/track.csv').readAsLinesSync();
  final head = lines.first.split(',');
  int col(String name) => head.indexOf(name);
  double? d(List<String> r, String name) {
    final i = col(name);
    if (i < 0 || i >= r.length || r[i].isEmpty) return null;
    return double.tryParse(r[i]);
  }

  final out = <TrackPoint>[];
  for (final line in lines.skip(1)) {
    final r = line.split(',');
    final lat = d(r, 'filtered_lat') ?? d(r, 'raw_lat');
    final lng = d(r, 'filtered_lng') ?? d(r, 'raw_lng');
    if (lat == null || lng == null) continue;
    out.add(TrackPoint(
      t: DateTime.parse(r[col('timestamp')]),
      elapsedMs: d(r, 'elapsed_ms')?.toInt(),
      lat: lat,
      lng: lng,
      speed: d(r, 'speed_mps') ?? 0,
      heading: d(r, 'heading_deg') ?? 0,
      spm: d(r, 'spm'),
      safetyLevel: r[col('safety_level')],
      rawLat: d(r, 'raw_lat'),
      rawLng: d(r, 'raw_lng'),
      speedAccuracyMetersPerSecond: d(r, 'speed_accuracy_mps'),
      rawGnssSpeedMetersPerSecond: d(r, 'raw_gnss_speed_mps'),
      distancePerStrokeMeters: d(r, 'distance_per_stroke_m'),
    ));
  }
  return out;
}
