import 'dart:math' as math;

import '../../config/record_replay_config.dart';
import 'replay_track.dart';

/// 区間（または複数の区間の合計）の統計。表示専用。
class RangeStats {
  /// 距離 [m]。
  final double distance;

  /// 区間の長さ [秒]（止まっていた時間を含む）。
  final double duration;

  /// 艇が動いていた時間 [秒]。平均 /500m はこの時間から出す。
  final double movingSec;

  /// 止まっていた時間 [秒]。
  final double stoppedSec;

  // 平均を足し合わせるための重み付きの和（複数区間の合計に使う）。
  final double spmWeighted;
  final double spmWeight;
  final double dpsWeighted;
  final double dpsWeight;

  const RangeStats({
    required this.distance,
    required this.duration,
    required this.movingSec,
    required this.stoppedSec,
    required this.spmWeighted,
    required this.spmWeight,
    required this.dpsWeighted,
    required this.dpsWeight,
  });

  static const empty = RangeStats(
    distance: 0,
    duration: 0,
    movingSec: 0,
    stoppedSec: 0,
    spmWeighted: 0,
    spmWeight: 0,
    dpsWeighted: 0,
    dpsWeight: 0,
  );

  /// 平均 /500m [秒]。20m 未満、または動いていなければ null。
  double? get paceSecPer500 =>
      distance >= 20 && movingSec > 0 ? movingSec * 500 / distance : null;

  /// 平均SR（練習の漕ぎの間だけの時間平均）。
  double? get averageSpm => spmWeight > 0 ? spmWeighted / spmWeight : null;

  /// 平均DPS [m]（練習の漕ぎの間だけの時間平均）。
  double? get averageDps => dpsWeight > 0 ? dpsWeighted / dpsWeight : null;

  RangeStats operator +(RangeStats o) => RangeStats(
        distance: distance + o.distance,
        duration: duration + o.duration,
        movingSec: movingSec + o.movingSec,
        stoppedSec: stoppedSec + o.stoppedSec,
        spmWeighted: spmWeighted + o.spmWeighted,
        spmWeight: spmWeight + o.spmWeight,
        dpsWeighted: dpsWeighted + o.dpsWeighted,
        dpsWeight: dpsWeight + o.dpsWeight,
      );
}

/// 距離で区切った区間（250mラップなど）。
class ReplayLap {
  final double fromMeters;
  final double toMeters;
  final ReplayRange range;
  final RangeStats stats;

  /// 区切りの距離に満たない最後の区間。平均の比較に入れない。
  final bool isPartial;

  const ReplayLap({
    required this.fromMeters,
    required this.toMeters,
    required this.range,
    required this.stats,
    required this.isPartial,
  });
}

/// [ReplayTrack] の上で区間の統計を出す（純Dart・表示専用）。
class RangeAnalyzer {
  final ReplayTrack track;

  const RangeAnalyzer(this.track);

  RangeStats stats(ReplayRange range) {
    if (track.length < 2 || range.end <= range.start) {
      return RangeStats.empty.copyWithDuration(math.max(0, range.duration));
    }
    final a = range.start, b = range.end;
    final i0 = track.indexAt(a);
    final ib = track.indexAt(b);
    final i1 = math.min(track.length - 1, ib + (track.t[ib] < b ? 1 : 0));
    var moving = 0.0, stopped = 0.0;
    var spmW = 0.0, spmN = 0.0, dpsW = 0.0, dpsN = 0.0;
    for (var i = i0 + 1; i <= i1; i++) {
      final dt = math.min(track.t[i], b) - math.max(track.t[i - 1], a);
      if (dt <= 0) continue;
      final v = track.speed[i];
      if (v >= replayMovingSpeedMps) {
        moving += dt;
      } else {
        stopped += dt;
      }
      if (v >= replayWorkSpeedMps) {
        final rate = track.spm[i];
        if (rate != null && rate > 0) {
          spmW += rate * dt;
          spmN += dt;
        }
        final dps = track.dpsAt(i);
        if (dps != null) {
          dpsW += dps * dt;
          dpsN += dt;
        }
      }
    }
    return RangeStats(
      distance: track.distanceAt(b) - track.distanceAt(a),
      duration: b - a,
      movingSec: moving,
      stoppedSec: stopped,
      spmWeighted: spmW,
      spmWeight: spmN,
      dpsWeighted: dpsW,
      dpsWeight: dpsN,
    );
  }

  /// 複数の区間の合計（セットの平均は本・区間の中だけで出す）。
  RangeStats combined(Iterable<ReplayRange> ranges) =>
      ranges.fold(RangeStats.empty, (sum, r) => sum + stats(r));

  /// [range] を [stepMeters] ごとに区切る。端数は50m以上なら残す。
  List<ReplayLap> laps(ReplayRange range, {double stepMeters = 250}) {
    final out = <ReplayLap>[];
    final i0 = track.indexAt(range.start), i1 = track.indexAt(range.end);
    final base = track.distanceAt(range.start);
    final end = track.distanceAt(range.end);
    var k = 1;
    var from = range.start;
    while (base + k * stepMeters <= end) {
      final t = track.timeAtDistance(base + k * stepMeters, i0, i1 + 1);
      if (t == null) break;
      final r = ReplayRange(from, t);
      out.add(ReplayLap(
        fromMeters: (k - 1) * stepMeters,
        toMeters: k * stepMeters,
        range: r,
        stats: stats(r),
        isPartial: false,
      ));
      from = t;
      k++;
    }
    final rest = end - (base + (k - 1) * stepMeters);
    if (rest >= 50) {
      final r = ReplayRange(from, range.end);
      out.add(ReplayLap(
        fromMeters: (k - 1) * stepMeters,
        toMeters: (k - 1) * stepMeters + rest,
        range: r,
        stats: stats(r),
        isPartial: true,
      ));
    }
    return out;
  }

  /// [within] の各区間の中で、[meters] を最も速く漕いだ区間。区間をまたがない。
  ReplayRange? fastest(double meters, Iterable<ReplayRange> within) {
    ReplayRange? best;
    final cd = track.cumulativeDistance, t = track.t;
    for (final w in within) {
      final i0 = track.indexAt(w.start), i1 = track.indexAt(w.end);
      var j = i0;
      for (var i = i0; i <= i1; i++) {
        while (j <= i1 && cd[j] - cd[i] < meters) {
          j++;
        }
        if (j > i1) break;
        final span = cd[j] - cd[j - 1];
        final r = span <= 1e-9 ? 1.0 : (cd[i] + meters - cd[j - 1]) / span;
        final end = t[j - 1] + (t[j] - t[j - 1]) * r;
        if (best == null || end - t[i] < best.duration) {
          best = ReplayRange(t[i], end);
        }
      }
    }
    return best;
  }
}

extension on RangeStats {
  RangeStats copyWithDuration(double d) => RangeStats(
        distance: distance,
        duration: d,
        movingSec: movingSec,
        stoppedSec: stoppedSec,
        spmWeighted: spmWeighted,
        spmWeight: spmWeight,
        dpsWeighted: dpsWeighted,
        dpsWeight: dpsWeight,
      );
}
