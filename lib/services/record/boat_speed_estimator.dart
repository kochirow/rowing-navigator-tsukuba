import 'dart:math' as math;

import '../../config/record_replay_config.dart';
import '../../models/session_model.dart';
import 'replay_track.dart';

/// 艇速の手がかり（候補）の種類。
enum SpeedCandidate {
  /// 生GPS位置の前後5秒の弦（直線距離）÷時間。
  gpsPosition('GPS位置'),

  /// GPSが直接測る速度（ドップラー）。
  gpsSpeed('GPS速度'),

  /// アプリの推定器が記録した艇速。
  appEstimate('アプリ推定艇速'),

  /// アプリがIMUで記録したDPS × SR ÷ 60。
  imu('IMU（DPS×SR）'),

  /// SR × DPS基準 ÷ 60（DPS基準はGPS位置とGPS速度が一致した点の中央値）。
  strokeRate('SR×DPS');

  final String label;
  const SpeedCandidate(this.label);
}

/// 候補ひとつの当たり具合。
class CandidateScore {
  final SpeedCandidate candidate;

  /// ほかの候補の中央値からの相対ずれの中央値。比べられる点が足りなければ null。
  final double? deviation;
  final int comparedSamples;
  final bool adopted;

  const CandidateScore({
    required this.candidate,
    required this.deviation,
    required this.comparedSamples,
    required this.adopted,
  });
}

/// 推定結果。[track] を記録画面の全計算に使い、[scores] は「タイムの推定に使った記録」に出す。
class EstimatedReplay {
  final ReplayTrack track;
  final List<CandidateScore> scores;

  const EstimatedReplay({required this.track, required this.scores});
}

/// 記録の点から、記録画面用の艇速と航跡を作る（純Dart・表示専用）。
///
/// アプリが記録した値（推定艇速・IMU）も候補に入れ、記録ごとにほかの候補との
/// ずれを測って採否を決める。版ごとに決め打ちしないので、推定器が良くなれば自動で使われ、
/// 悪ければ自動で外れる。手順と検証は設計書 §6.5。
class BoatSpeedEstimator {
  const BoatSpeedEstimator();

  EstimatedReplay estimate(List<TrackPoint> points,
      {String boatTypeName = ''}) {
    final pts = _orderedPoints(points);
    final n = pts.length;
    final t = [for (final p in pts) p.time];
    final heading = [for (final p in pts) p.point.heading];

    // 生GPS位置を前後1点でならす（ならした位置を地図と弦の両方に使う）。
    final lat = List<double>.filled(n, 0), lng = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      var sLat = 0.0, sLng = 0.0, c = 0;
      for (var k = math.max(0, i - 1); k <= math.min(n - 1, i + 1); k++) {
        if ((t[k] - t[i]).abs() > 3.5) continue;
        sLat += pts[k].point.rawLat ?? pts[k].point.lat;
        sLng += pts[k].point.rawLng ?? pts[k].point.lng;
        c++;
      }
      lat[i] = sLat / c;
      lng[i] = sLng / c;
    }

    // SRの欠けを直前の値で埋める（漕いでいる間・6秒まで）。
    final spm = List<double?>.filled(n, null);
    double? lastSpm;
    double lastSpmAt = double.negativeInfinity;
    for (var i = 0; i < n; i++) {
      final p = pts[i].point;
      if (p.spm != null) {
        spm[i] = p.spm;
        lastSpm = p.spm;
        lastSpmAt = t[i];
        continue;
      }
      final v = _validSpeed(p.rawGnssSpeedMetersPerSecond) ?? p.speed;
      if (lastSpm != null &&
          t[i] - lastSpmAt <= replaySpmCarryForwardSec &&
          v >= replayWorkSpeedMps) {
        spm[i] = lastSpm;
      }
    }

    final cand = <SpeedCandidate, List<double?>>{
      SpeedCandidate.gpsPosition: _chordSpeed(t, lat, lng),
      SpeedCandidate.gpsSpeed: [
        for (final p in pts)
          (p.point.speedAccuracyMetersPerSecond == null ||
                  p.point.speedAccuracyMetersPerSecond! <=
                      replayDopplerMaxAccuracyMps)
              ? _validSpeed(p.point.rawGnssSpeedMetersPerSecond)
              : null,
      ],
      SpeedCandidate.appEstimate: [
        for (final p in pts) _validSpeed(p.point.speed)
      ],
      SpeedCandidate.imu: [
        for (var i = 0; i < n; i++)
          pts[i].point.distancePerStrokeMeters != null && spm[i] != null
              ? pts[i].point.distancePerStrokeMeters! * spm[i]! / 60
              : null,
      ],
    };
    cand[SpeedCandidate.strokeRate] = _strokeRateSpeed(t, spm,
        cand[SpeedCandidate.gpsPosition]!, cand[SpeedCandidate.gpsSpeed]!);

    // 1) 全候補を同じ10秒平均にそろえる。
    final smoothed = {
      for (final e in cand.entries)
        e.key: _centerMean(t, e.value, replayCandidateHalfWindowSec)
    };
    // 2) 記録ごとのずれ 3) 採否
    final deviations = <SpeedCandidate, (double?, int)>{};
    for (final k in SpeedCandidate.values) {
      final dev = <double>[];
      for (var i = 0; i < n; i++) {
        final x = smoothed[k]![i];
        if (x == null) continue;
        final others = <double>[
          for (final j in SpeedCandidate.values)
            if (j != k && smoothed[j]![i] != null) smoothed[j]![i]!
        ];
        if (others.isEmpty) continue;
        final m = _median(others)!;
        if (m < replayWorkSpeedMps) continue;
        dev.add((x - m).abs() / m);
      }
      deviations[k] = (
        dev.length >= replayCandidateMinCompareSamples ? _median(dev) : null,
        dev.length,
      );
    }
    final best = SpeedCandidate.values
        .map((k) => deviations[k]!.$1 ?? double.infinity)
        .reduce(math.min);
    final threshold =
        math.max(best * replayCandidateAdoptRatio, replayCandidateAdoptFloor);
    final adopted = [
      for (final k in SpeedCandidate.values)
        if (deviations[k]!.$1 != null && deviations[k]!.$1! <= threshold) k
    ];

    // 4) 中央値 → 上限 → 加速度の制限 → 10秒中心平均
    final cap = 2000 /
        (replayWorldBest2000mSec[_boatKey(boatTypeName)] ??
            replayWorldBest2000mSec['1x']!) *
        replayWorldBestMargin;
    final raw = List<double>.filled(n, 0);
    double? prev;
    for (var i = 0; i < n; i++) {
      final c = [
        for (final k in adopted)
          if (smoothed[k]![i] != null) smoothed[k]![i]!
      ];
      var v = c.isNotEmpty
          ? _median(c)!
          : (prev ?? _validSpeed(pts[i].point.speed) ?? 0);
      v = math.min(v, cap);
      raw[i] = v;
      prev = v;
    }
    final fwd = [...raw], bwd = [...raw];
    for (var i = 1; i < n; i++) {
      final d = replayMaxAccelerationMps2 * math.max(0.5, t[i] - t[i - 1]);
      fwd[i] = fwd[i].clamp(fwd[i - 1] - d, fwd[i - 1] + d);
    }
    for (var i = n - 2; i >= 0; i--) {
      final d = replayMaxAccelerationMps2 * math.max(0.5, t[i + 1] - t[i]);
      bwd[i] = bwd[i].clamp(bwd[i + 1] - d, bwd[i + 1] + d);
    }
    final limited = <double?>[
      for (var i = 0; i < n; i++) (fwd[i] + bwd[i]) / 2
    ];
    final speed = [
      for (final v in _centerMean(t, limited, replayOutputHalfWindowSec))
        v ?? 0.0
    ];

    return EstimatedReplay(
      track: ReplayTrack(
          t: t, lat: lat, lng: lng, heading: heading, speed: speed, spm: spm),
      scores: [
        for (final k in SpeedCandidate.values)
          CandidateScore(
            candidate: k,
            deviation: deviations[k]!.$1,
            comparedSamples: deviations[k]!.$2,
            adopted: adopted.contains(k),
          ),
      ],
    );
  }

  /// 経過時間（`elapsedMs`、なければ時刻の差）で並べ、時刻が進まない点を落とす。
  static List<_TimedPoint> _orderedPoints(List<TrackPoint> points) {
    if (points.isEmpty) return const [];
    final useElapsed = points.every((p) => p.elapsedMs != null);
    final t0 = points.first.t;
    final e0 = points.first.elapsedMs ?? 0;
    final out = <_TimedPoint>[];
    for (final p in points) {
      final time = useElapsed
          ? (p.elapsedMs! - e0) / 1000.0
          : p.t.difference(t0).inMilliseconds / 1000.0;
      if (out.isNotEmpty && time <= out.last.time) continue;
      out.add(_TimedPoint(time, p));
    }
    return out;
  }

  static double? _validSpeed(double? v) =>
      v != null && v.isFinite && v >= 0 ? v : null;

  static List<double?> _chordSpeed(
      List<double> t, List<double> lat, List<double> lng) {
    final n = t.length;
    final out = List<double?>.filled(n, null);
    var a = 0, b = 0;
    for (var i = 0; i < n; i++) {
      while (a < i && t[i] - t[a + 1] >= replayPositionChordHalfWindowSec) {
        a++;
      }
      while (b + 1 < n && t[b + 1] - t[i] <= replayPositionChordHalfWindowSec) {
        b++;
      }
      final span = t[b] - t[a];
      if (span >= replayPositionChordMinSpanSec &&
          span <= replayPositionChordMaxSpanSec) {
        out[i] = _haversine(lat[a], lng[a], lat[b], lng[b]) / span;
      }
    }
    return out;
  }

  static List<double?> _strokeRateSpeed(
      List<double> t, List<double?> spm, List<double?> pos, List<double?> dop) {
    final obsT = <double>[], obsDps = <double>[];
    for (var i = 0; i < t.length; i++) {
      final sr = spm[i], x = pos[i], y = dop[i];
      if (sr == null || x == null || y == null || x <= replayWorkSpeedMps) {
        continue;
      }
      if ((x - y).abs() / math.max(x, y) >= replayDpsAgreementTolerance) {
        continue;
      }
      obsT.add(t[i]);
      obsDps.add((x + y) / 2 * 60 / sr);
    }
    final out = List<double?>.filled(t.length, null);
    var j0 = 0, j1 = 0;
    for (var i = 0; i < t.length; i++) {
      while (j0 < obsT.length &&
          obsT[j0] < t[i] - replayDpsReferenceHalfWindowSec) {
        j0++;
      }
      while (j1 < obsT.length &&
          obsT[j1] <= t[i] + replayDpsReferenceHalfWindowSec) {
        j1++;
      }
      final sr = spm[i];
      if (sr != null && j1 - j0 >= replayDpsReferenceMinSamples) {
        out[i] = sr * _median(obsDps.sublist(j0, j1))! / 60;
      }
    }
    return out;
  }

  static List<double?> _centerMean(
      List<double> t, List<double?> v, double half) {
    final n = t.length;
    final out = List<double?>.filled(n, null);
    var a = 0, b = 0;
    for (var i = 0; i < n; i++) {
      while (t[i] - t[a] > half) {
        a++;
      }
      while (b + 1 < n && t[b + 1] - t[i] <= half) {
        b++;
      }
      var s = 0.0, c = 0;
      for (var k = a; k <= b; k++) {
        final x = v[k];
        if (x != null && x.isFinite) {
          s += x;
          c++;
        }
      }
      out[i] = c > 0 ? s / c : null;
    }
    return out;
  }

  static double? _median(List<double> values) {
    if (values.isEmpty) return null;
    final s = [...values]..sort();
    final m = s.length ~/ 2;
    return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
  }

  static double _haversine(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLng = (lng2 - lng1) * math.pi / 180;
    final h = math.pow(math.sin(dLat / 2), 2) +
        math.cos(lat1 * math.pi / 180) *
            math.cos(lat2 * math.pi / 180) *
            math.pow(math.sin(dLng / 2), 2);
    return 2 * r * math.asin(math.sqrt(h));
  }

  /// 保存されている艇種名（例: r_4x、旧記録の 4x）を世界最高の表のキーにする。
  static String _boatKey(String boatTypeName) {
    final s = boatTypeName.toLowerCase();
    if (s.contains('8')) return '8+';
    if (s.contains('4')) return '4x';
    if (s.contains('2')) return '2x';
    return '1x';
  }
}

class _TimedPoint {
  final double time;
  final TrackPoint point;
  const _TimedPoint(this.time, this.point);
}
