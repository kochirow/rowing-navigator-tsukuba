import 'dart:math' as math;

import '../../config/record_replay_config.dart';

/// 記録画面で使う、時刻順の航跡（表示専用）。
///
/// 時刻は記録の開始からの秒。艇速は推定済みの値（`BoatSpeedEstimator`）を受け取り、
/// 距離はその艇速を時間で積分して作る。/500m・SR・DPS・距離がすべて同じ艇速から
/// 出るようにするため、GPS位置の点ごとの距離は使わない（設計書 §6.5）。
class ReplayTrack {
  final List<double> t;
  final List<double> lat;
  final List<double> lng;
  final List<double> heading;

  /// 推定した艇速 [m/s]。
  final List<double> speed;

  /// ストロークレート。欠けは null。
  final List<double?> spm;

  /// 積算距離 [m]。
  final List<double> cumulativeDistance;

  ReplayTrack._({
    required this.t,
    required this.lat,
    required this.lng,
    required this.heading,
    required this.speed,
    required this.spm,
    required this.cumulativeDistance,
  });

  factory ReplayTrack({
    required List<double> t,
    required List<double> lat,
    required List<double> lng,
    required List<double> heading,
    required List<double> speed,
    required List<double?> spm,
  }) {
    final n = t.length;
    if (lat.length != n ||
        lng.length != n ||
        heading.length != n ||
        speed.length != n ||
        spm.length != n) {
      throw ArgumentError('ReplayTrack の配列の長さがそろっていない');
    }
    final cd = List<double>.filled(n, 0);
    for (var i = 1; i < n; i++) {
      final dt = math.min(replayMaxIntegrationStepSec, t[i] - t[i - 1]);
      final vm = (speed[i] + speed[i - 1]) / 2;
      cd[i] = cd[i - 1] + (dt > 0 && vm >= replayMovingSpeedMps ? vm * dt : 0);
    }
    return ReplayTrack._(
      t: List.unmodifiable(t),
      lat: List.unmodifiable(lat),
      lng: List.unmodifiable(lng),
      heading: List.unmodifiable(heading),
      speed: List.unmodifiable(speed),
      spm: List.unmodifiable(spm),
      cumulativeDistance: List.unmodifiable(cd),
    );
  }

  int get length => t.length;
  bool get isEmpty => t.isEmpty;
  double get duration => isEmpty ? 0 : t.last;
  double get totalDistance => isEmpty ? 0 : cumulativeDistance.last;

  /// 時刻 [time] 以前で最も新しい点の番号（範囲外は端に丸める）。
  int indexAt(double time) {
    if (isEmpty) return 0;
    var lo = 0, hi = t.length - 1;
    while (lo < hi) {
      final m = (lo + hi + 1) >> 1;
      if (t[m] <= time) {
        lo = m;
      } else {
        hi = m - 1;
      }
    }
    return lo;
  }

  double _ratio(int i, double time) {
    if (i >= t.length - 1) return 0;
    final span = t[i + 1] - t[i];
    if (span <= 0) return 0;
    return ((time - t[i]) / span).clamp(0.0, 1.0);
  }

  /// 時刻 [time] の積算距離（前後の点で補間）。
  double distanceAt(double time) {
    if (isEmpty) return 0;
    final i = indexAt(time);
    if (i >= t.length - 1) return cumulativeDistance.last;
    final r = _ratio(i, time);
    return cumulativeDistance[i] +
        (cumulativeDistance[i + 1] - cumulativeDistance[i]) * r;
  }

  /// 時刻 [time] の位置（前後の点で補間）と向き（直前の点）。
  ({double lat, double lng, double heading}) positionAt(double time) {
    final i = indexAt(time);
    if (i >= t.length - 1) {
      return (lat: lat.last, lng: lng.last, heading: heading.last);
    }
    final r = _ratio(i, time);
    return (
      lat: lat[i] + (lat[i + 1] - lat[i]) * r,
      lng: lng[i] + (lng[i + 1] - lng[i]) * r,
      heading: heading[i],
    );
  }

  /// [fromIndex]〜[toIndex] の間で、積算距離が [distance] に達する時刻。届かなければ null。
  double? timeAtDistance(double distance, int fromIndex, int toIndex) {
    final end = math.min(t.length - 1, toIndex);
    for (var i = math.max(1, fromIndex); i <= end; i++) {
      if (cumulativeDistance[i] >= distance) {
        final span = cumulativeDistance[i] - cumulativeDistance[i - 1];
        final r =
            span <= 1e-9 ? 1.0 : (distance - cumulativeDistance[i - 1]) / span;
        return t[i - 1] + (t[i] - t[i - 1]) * r;
      }
    }
    return null;
  }

  /// 艇速から作る DPS [m]。練習の漕ぎ（500m=4:00より速い）でSRがあるときだけ。
  double? dpsAt(int i) {
    final rate = spm[i];
    if (rate == null || rate <= 0 || speed[i] < replayWorkSpeedMps) return null;
    return speed[i] * 60 / rate;
  }
}

/// 時刻の区間 [start, end]（記録の開始からの秒）。
class ReplayRange {
  final double start;
  final double end;

  const ReplayRange(this.start, this.end);

  double get duration => end - start;
  bool contains(double time) => time >= start && time <= end;

  @override
  bool operator ==(Object other) =>
      other is ReplayRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'ReplayRange($start, $end)';
}
