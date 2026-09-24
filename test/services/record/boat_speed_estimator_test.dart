import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/session_model.dart';
import 'package:rowing_navigator/services/record/boat_speed_estimator.dart';

const _mPerDegLat = 111320.0;

/// 北向きに進む1Hzの記録。真の艇速 [trueSpeed] から各候補を作り、[edit] で崩す。
List<TrackPoint> session(
  int seconds,
  double Function(int) trueSpeed, {
  double? spm = 20,
  double dps = 12,
  bool withRaw = true,
  TrackPoint Function(int i, TrackPoint p)? edit,
  int seed = 1,
}) {
  final rnd = math.Random(seed);
  final t0 = DateTime(2026, 8, 6, 6);
  var y = 0.0;
  final out = <TrackPoint>[];
  for (var i = 0; i <= seconds; i++) {
    final v = trueSpeed(i);
    if (i > 0) y += v;
    final noise = (rnd.nextDouble() - 0.5) * 2.0; // ±1m の位置の揺れ
    final lat = 36.08 + (y + noise) / _mPerDegLat;
    var p = TrackPoint(
      t: t0.add(Duration(seconds: i)),
      elapsedMs: i * 1000,
      lat: lat,
      lng: 140.21,
      speed: v,
      heading: 0,
      spm: v > 2.5 ? spm : null,
      safetyLevel: 'safe',
      rawLat: withRaw ? lat : null,
      rawLng: withRaw ? 140.21 : null,
      rawGnssSpeedMetersPerSecond:
          withRaw ? v + (rnd.nextDouble() - 0.5) * 0.3 : null,
      speedAccuracyMetersPerSecond: withRaw ? 0.9 : null,
      distancePerStrokeMeters: v > 2.5 && spm != null ? dps : null,
    );
    if (edit != null) p = edit(i, p);
    out.add(p);
  }
  return out;
}

TrackPoint copy(TrackPoint p, {double? lat, double? speed, double? dps}) =>
    TrackPoint(
      t: p.t,
      elapsedMs: p.elapsedMs,
      lat: lat ?? p.lat,
      lng: p.lng,
      speed: speed ?? p.speed,
      heading: p.heading,
      spm: p.spm,
      safetyLevel: p.safetyLevel,
      rawLat: p.rawLat,
      rawLng: p.rawLng,
      rawGnssSpeedMetersPerSecond: p.rawGnssSpeedMetersPerSecond,
      speedAccuracyMetersPerSecond: p.speedAccuracyMetersPerSecond,
      distancePerStrokeMeters: dps ?? p.distancePerStrokeMeters,
    );

void main() {
  const estimator = BoatSpeedEstimator();

  test('アプリ推定の位置と艇速が跳んでも、生GPS・GPS速度が正しければ推定は跳ばない（8/6 4x の再現）', () {
    final pts = session(400, (_) => 4.0, edit: (i, p) {
      if (i >= 200 && i < 204) {
        // 補正後の位置が2秒で12m跳び、推定艇速も6.5m/sに跳ぶ
        return copy(p, lat: p.lat + 12 / _mPerDegLat, speed: 6.5);
      }
      return p;
    });
    final r = estimator.estimate(pts, boatTypeName: 'r_4x');
    for (var i = 190; i <= 215; i++) {
      expect(r.track.speed[i], closeTo(4.0, 0.15), reason: 't=$i');
    }
  });

  test('ずっと外れている候補は採用しない', () {
    final pts = session(400, (_) => 4.0,
        edit: (i, p) => copy(p, speed: 5.5)); // アプリ推定艇速だけ38%速い
    final r = estimator.estimate(pts, boatTypeName: 'r_4x');
    final app =
        r.scores.firstWhere((s) => s.candidate == SpeedCandidate.appEstimate);
    expect(app.adopted, isFalse);
    expect(r.track.speed[200], closeTo(4.0, 0.15));
  });

  test('よく一致する候補は、アプリの記録値でも採用する（余地を残す）', () {
    final r =
        estimator.estimate(session(400, (_) => 4.0), boatTypeName: 'r_4x');
    final app =
        r.scores.firstWhere((s) => s.candidate == SpeedCandidate.appEstimate);
    expect(app.adopted, isTrue);
    expect(app.deviation, lessThan(0.03));
  });

  test('生GPS・GPS速度・SRのない古い記録でも推定できる（縮退）', () {
    final pts = session(300, (_) => 3.8, withRaw: false, spm: null);
    final r = estimator.estimate(pts, boatTypeName: 'r_1x');
    expect(r.track.speed[150], closeTo(3.8, 0.2));
    expect(r.track.spm.every((s) => s == null), isTrue);
  });

  test('スタートの加速（0→5m/sを15秒）は加速度の制限で削られない', () {
    final pts = session(200, (i) => i < 50 ? 0.0 : math.min(5.0, (i - 50) / 3));
    final r = estimator.estimate(pts, boatTypeName: 'r_8p');
    expect(r.track.speed[75], closeTo(5.0, 0.2));
  });

  test('艇種の世界最高より速い値は切る', () {
    final pts = session(300, (_) => 7.0, spm: 40, dps: 10.5);
    final r = estimator.estimate(pts, boatTypeName: 'r_4x');
    expect(r.track.speed[150], lessThanOrEqualTo(2000 / 332.03 * 1.02 + 1e-9));
  });

  test('時刻が戻る点・同じ時刻の点は落とし、経過時間で並べる', () {
    final pts = session(100, (_) => 4.0);
    final shuffled = [...pts.take(50), pts[30], pts[49], ...pts.skip(50)];
    final r = estimator.estimate(shuffled, boatTypeName: 'r_4x');
    expect(r.track.length, pts.length);
    for (var i = 1; i < r.track.length; i++) {
      expect(r.track.t[i], greaterThan(r.track.t[i - 1]));
    }
  });

  test('空・1点の記録でも落ちない', () {
    expect(estimator.estimate(const []).track.isEmpty, isTrue);
    final one = estimator.estimate(session(0, (_) => 0));
    expect(one.track.length, 1);
  });

  test('SRの欠けは漕いでいる間だけ6秒まで直前の値で埋める', () {
    final pts = session(60, (_) => 4.0, edit: (i, p) {
      if (i % 5 == 0) return p;
      return TrackPoint(
        t: p.t,
        elapsedMs: p.elapsedMs,
        lat: p.lat,
        lng: p.lng,
        speed: p.speed,
        heading: 0,
        safetyLevel: 'safe',
        rawLat: p.rawLat,
        rawLng: p.rawLng,
        rawGnssSpeedMetersPerSecond: p.rawGnssSpeedMetersPerSecond,
      );
    });
    final r = estimator.estimate(pts, boatTypeName: 'r_4x');
    expect(r.track.spm.skip(1).every((s) => s == 20), isTrue);
  });
}
