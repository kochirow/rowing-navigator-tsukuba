import 'dart:math' as math;

import '../../config/log_config.dart';
import '../../config/record_replay_config.dart';
import '../../config/rowing_pace_config.dart';
import 'range_analyzer.dart';
import 'replay_track.dart';

/// セットの強度（設計書 §7.0）。
enum TrainingIntensity {
  ut('UT', '区間'),
  at('AT', '区間'),
  highRate('ハイレート', '本');

  /// 画面に出す名前。
  final String label;

  /// セットの中身の数え方（ハイレートは「N本目」、UT・ATは「N区間目」）。
  final String unit;
  const TrainingIntensity(this.label, this.unit);
}

/// 本と本のすき間の中身。
enum GapKind {
  turn('ターン'),
  stop('停止'),
  paddle('パドル');

  final String label;
  const GapKind(this.label);
}

/// セットの中の1本（ハイレート）または1区間（UT・AT）。
class TrainingBout {
  final ReplayRange range;
  final RangeStats stats;
  final int setIndex;
  final int indexInSet;

  const TrainingBout({
    required this.range,
    required this.stats,
    required this.setIndex,
    required this.indexInSet,
  });
}

/// 同じ強度で続けた練習のかたまり。平均は本・区間の中だけで出す。
class TrainingSet {
  final int index;
  final TrainingIntensity intensity;
  final List<TrainingBout> bouts;

  /// 最初の本の始まりから最後の本の終わりまで。
  final ReplayRange range;

  /// 本・区間の合計（レスト・ターンを除く）。
  final RangeStats stats;

  /// 漕いでいた時間（本・区間の長さの合計）[秒]。
  final double rowingSec;

  /// 本と本の間の時間の合計 [秒]。
  double get restSec => range.duration - rowingSec;

  const TrainingSet({
    required this.index,
    required this.intensity,
    required this.bouts,
    required this.range,
    required this.stats,
    required this.rowingSec,
  });
}

/// 記録をセットに分ける（純Dart・表示専用）。手順は設計書 §7.0。
class TrainingSetDetector {
  const TrainingSetDetector();

  List<TrainingSet> detect(ReplayTrack track, {String boatTypeName = ''}) {
    if (track.length < 2) return const [];
    final analyzer = RangeAnalyzer(track);
    final srs = _smoothedSpm(track);

    // 1) ハイレートの本（先に探す。つなぎのパドルは艇速だけ見ると「漕いでいる」になるため）
    final highBouts = _highRateBouts(track, srs);

    // 2) 5分以内に続くハイレートの本を1セットにまとめる
    final groups = <({TrainingIntensity kind, List<ReplayRange> bouts})>[];
    for (final b in highBouts) {
      final last = groups.isEmpty ? null : groups.last;
      if (last != null &&
          last.kind == TrainingIntensity.highRate &&
          b.start - last.bouts.last.end <= replayHighRateSetMaxRestSec) {
        last.bouts.add(b);
      } else {
        groups.add((kind: TrainingIntensity.highRate, bouts: [b]));
      }
    }

    // 3) 残りの時間から一定のペースで漕いだ区間（UT・AT）を探す
    final mask = List<bool>.filled(track.length, false);
    for (final g in groups) {
      final from =
          track.indexAt(g.bouts.first.start - replayHighRateMaskMarginSec);
      final to = track.indexAt(g.bouts.last.end + replayHighRateMaskMarginSec);
      for (var i = from; i <= to; i++) {
        mask[i] = true;
      }
    }
    final steady = <({TrainingIntensity kind, List<ReplayRange> bouts})>[];
    for (final r in _steadyBouts(track, mask, boatTypeName)) {
      final spm = analyzer.stats(r).averageSpm;
      final kind = spm == null || spm < replaySteadyUtMaxSpm
          ? TrainingIntensity.ut
          : spm < replayHighRateSpm
              ? TrainingIntensity.at
              : TrainingIntensity.highRate;
      final last = steady.isEmpty ? null : steady.last;
      if (last != null &&
          last.kind == kind &&
          r.start - last.bouts.last.end <= replaySteadySetMaxGapSec) {
        last.bouts.add(r);
      } else {
        steady.add((kind: kind, bouts: [r]));
      }
    }

    final all = [...groups, ...steady]
      ..sort((a, b) => a.bouts.first.start.compareTo(b.bouts.first.start));
    return [
      for (var si = 0; si < all.length; si++)
        _buildSet(si, all[si].kind, all[si].bouts, analyzer),
    ];
  }

  /// 本と本のすき間 [gap] の中身。向きが120°以上変わった=ターン、6割以上止まっていた=停止。
  GapKind gapKind(ReplayTrack track, ReplayRange gap) {
    var stopped = 0.0, total = 0.0;
    final i0 = track.indexAt(gap.start);
    final i1 = math.min(track.length - 1, track.indexAt(gap.end) + 1);
    for (var i = i0 + 1; i <= i1; i++) {
      final dt =
          math.min(track.t[i], gap.end) - math.max(track.t[i - 1], gap.start);
      if (dt <= 0) continue;
      total += dt;
      if (track.speed[i] < replayMovingSpeedMps) stopped += dt;
    }
    var dh = (track.heading[track.indexAt(gap.end)] -
                track.heading[track.indexAt(gap.start)])
            .abs() %
        360;
    if (dh > 180) dh = 360 - dh;
    if (dh >= replayTurnHeadingChangeDeg) return GapKind.turn;
    if (total > 0 && stopped / total >= replayStoppedFraction) {
      return GapKind.stop;
    }
    return GapKind.paddle;
  }

  TrainingSet _buildSet(int index, TrainingIntensity kind,
      List<ReplayRange> ranges, RangeAnalyzer analyzer) {
    final bouts = [
      for (var j = 0; j < ranges.length; j++)
        TrainingBout(
          range: ranges[j],
          stats: analyzer.stats(ranges[j]),
          setIndex: index,
          indexInSet: j,
        ),
    ];
    return TrainingSet(
      index: index,
      intensity: kind,
      bouts: bouts,
      range: ReplayRange(ranges.first.start, ranges.last.end),
      stats: bouts.fold(RangeStats.empty, (s, b) => s + b.stats),
      rowingSec: ranges.fold(0.0, (s, r) => s + r.duration),
    );
  }

  /// 動いている点の、前後4秒のSRの中央値。陸上の揺れ（SR60前後）は範囲外として捨てる。
  static List<double?> _smoothedSpm(ReplayTrack tr) {
    final n = tr.length;
    final out = List<double?>.filled(n, null);
    bool usable(int k) {
      final s = tr.spm[k];
      return s != null &&
          s >= replayValidSpmMin &&
          s <= replayValidSpmMax &&
          tr.speed[k] >= replayMovingSpeedMps;
    }

    for (var i = 0; i < n; i++) {
      final v = <double>[];
      for (var k = i;
          k >= 0 && tr.t[i] - tr.t[k] <= replaySpmSmoothingHalfWindowSec;
          k--) {
        if (usable(k)) v.add(tr.spm[k]!);
      }
      for (var k = i + 1;
          k < n && tr.t[k] - tr.t[i] <= replaySpmSmoothingHalfWindowSec;
          k++) {
        if (usable(k)) v.add(tr.spm[k]!);
      }
      if (v.isEmpty) continue;
      v.sort();
      final m = v.length ~/ 2;
      out[i] = v.length.isOdd ? v[m] : (v[m - 1] + v[m]) / 2;
    }
    return out;
  }

  static List<ReplayRange> _highRateBouts(ReplayTrack tr, List<double?> srs) {
    final out = <ReplayRange>[];
    bool isHigh(int i) =>
        srs[i] != null &&
        srs[i]! >= replayHighRateSpm &&
        tr.speed[i] >= replayWorkSpeedMps;
    int? s0, last;
    void close() {
      if (s0 == null || last == null) return;
      var a = s0!;
      while (a > 0 &&
          tr.t[s0!] - tr.t[a - 1] <= replayHighRateLeadSec &&
          srs[a - 1] != null &&
          srs[a - 1]! >= replayHighRateLeadSpm &&
          tr.speed[a - 1] >= replayWorkSpeedMps) {
        a--;
      }
      if (tr.t[last!] - tr.t[a] >= replayHighRateMinDurationSec &&
          tr.cumulativeDistance[last!] - tr.cumulativeDistance[a] >=
              replayHighRateMinDistanceMeters) {
        out.add(ReplayRange(tr.t[a], tr.t[last!]));
      }
      s0 = null;
      last = null;
    }

    for (var i = 0; i < tr.length; i++) {
      if (isHigh(i)) {
        s0 ??= i;
        last = i;
      } else if (s0 != null &&
          tr.t[i] - tr.t[last!] > replayHighRateMaxGapSec) {
        close();
      }
    }
    close();
    return out;
  }

  /// 既存のピース判定（艇種別の表示基準より速い区間）を、[mask] の外で行う。
  static List<ReplayRange> _steadyBouts(
      ReplayTrack tr, List<bool> mask, String boatTypeName) {
    final minSpeed =
        RowingPaceProfile.forBoatTypeName(boatTypeName).minimumDisplaySpeedMps;
    double smoothed(int i) {
      var ws = 0.0, el = 0.0;
      for (var k = i; k > 0; k--) {
        final dt = tr.t[k] - tr.t[k - 1];
        if (dt <= 0) continue;
        if (tr.t[i] - tr.t[k - 1] > pieceSpeedSmoothingWindowSec) break;
        ws += tr.speed[k] * dt;
        el += dt;
      }
      return el > 0 ? ws / el : tr.speed[i];
    }

    final raw = <ReplayRange>[];
    int? s0, last;
    void close(int e) {
      if (s0 == null) return;
      final dur = tr.t[e] - tr.t[s0!];
      final dist = tr.cumulativeDistance[e] - tr.cumulativeDistance[s0!];
      if (dur >= pieceMinDurationSec && dist >= pieceMinDistanceMeters) {
        raw.add(ReplayRange(tr.t[s0!], tr.t[e]));
      }
      s0 = null;
      last = null;
    }

    for (var i = 0; i < tr.length; i++) {
      final fast =
          !mask[i] && (tr.speed[i] > minSpeed || smoothed(i) > minSpeed);
      if (fast) {
        s0 ??= i;
        last = i;
      } else if (s0 != null &&
          last != null &&
          tr.t[i] - tr.t[last!] > pieceMaxGapSec) {
        close(last!);
      }
    }
    if (s0 != null && last != null) close(last!);

    final merged = <ReplayRange>[];
    for (final r in raw) {
      if (merged.isNotEmpty &&
          r.start - merged.last.end <= replaySteadyMergeGapSec) {
        merged[merged.length - 1] = ReplayRange(merged.last.start, r.end);
      } else {
        merged.add(r);
      }
    }
    return [
      for (final r in merged)
        if (r.duration >= replaySteadyMinDurationSec &&
            tr.distanceAt(r.end) - tr.distanceAt(r.start) >=
                replaySteadyMinDistanceMeters)
          r,
    ];
  }
}
