// 記録画面の艇速推定（lib/services/record/boat_speed_estimator.dart）を、
// 同じ艇に同乗した2台の実機ログで検証する（設計書 §6.5 のものさし）。
//
// 真の艇速は2台で共通、GPS誤差は端末ごとに独立なので、2台の推定の一致が良いほど
// 誤差を消せている。HTML試作（Python）での値は 中央 1.54 秒 / p90 4.85 秒（/500m の差）。
//
//   flutter test tool/replay_speed_estimator.dart \
//     --dart-define=LOG_A=/path/to/rowing_diagnostics_1785967606648 \
//     --dart-define=LOG_B=/path/to/rowing_diagnostics_1785967619060 \
//     --dart-define=BOAT=r_8p
//
// LOG_A / LOG_B が無い場合はスキップする（CIでは走らない）。
// 診断パッケージは個人の航跡を含むためリポジトリには入れない。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/record_replay_config.dart';
import 'package:rowing_navigator/models/session_model.dart';
import 'package:rowing_navigator/services/record/boat_speed_estimator.dart';
import 'package:rowing_navigator/services/record/replay_track.dart';

const _logA = String.fromEnvironment('LOG_A');
const _logB = String.fromEnvironment('LOG_B');
const _boat = String.fromEnvironment('BOAT', defaultValue: 'r_8p');

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

double? speedAtAbsolute(ReplayTrack tr, DateTime start, DateTime at) {
  final time = at.difference(start).inMilliseconds / 1000.0;
  if (time < 0 || time > tr.duration) return null;
  final i = tr.indexAt(time);
  if (i >= tr.length - 1) return tr.speed[i];
  if (tr.t[i + 1] - tr.t[i] > 4) return null;
  final r = (time - tr.t[i]) / (tr.t[i + 1] - tr.t[i]);
  return tr.speed[i] + (tr.speed[i + 1] - tr.speed[i]) * r;
}

void main() {
  test('同乗2台の艇速推定の一致', () {
    final a = readTrack(_logA), b = readTrack(_logB);
    const est = BoatSpeedEstimator();
    final ra = est.estimate(a, boatTypeName: _boat);
    final rb = est.estimate(b, boatTypeName: _boat);
    final t0 = a.first.t.isAfter(b.first.t) ? a.first.t : b.first.t;
    final t1 = a.last.t.isBefore(b.last.t) ? a.last.t : b.last.t;
    final diffs = <double>[];
    for (var at = t0.add(const Duration(seconds: 60));
        at.isBefore(t1);
        at = at.add(const Duration(seconds: 2))) {
      final va = speedAtAbsolute(ra.track, a.first.t, at);
      final vb = speedAtAbsolute(rb.track, b.first.t, at);
      if (va == null || vb == null) continue;
      if (va < replayWorkSpeedMps + 0.3 || vb < replayWorkSpeedMps + 0.3) {
        continue;
      }
      diffs.add((500 / va - 500 / vb).abs());
    }
    diffs.sort();
    double q(double p) =>
        diffs[(diffs.length * p).floor().clamp(0, diffs.length - 1)];
    String scores(EstimatedReplay r) => r.scores
        .map((s) =>
            '${s.candidate.label}:${s.deviation == null ? '-' : (s.deviation! * 100).toStringAsFixed(1)}%${s.adopted ? '○' : '×'}')
        .join(' ');
    // ignore: avoid_print
    print('評価点 ${diffs.length} / 2台の /500m 差 中央 ${q(.5).toStringAsFixed(2)}'
        ' p90 ${q(.9).toStringAsFixed(2)} p99 ${q(.99).toStringAsFixed(2)} 秒\n'
        'A: ${scores(ra)}\nB: ${scores(rb)}');
    expect(diffs, isNotEmpty);
  }, skip: _logA.isEmpty || _logB.isEmpty ? 'LOG_A / LOG_B が無い' : false);
}
