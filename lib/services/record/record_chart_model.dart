import 'dart:math' as math;

import '../../config/record_replay_config.dart';
import 'replay_track.dart';

/// グラフの指標。/500m は上が速い（数値の小さい方を上に描く）。
enum ChartMetric {
  pace('/500m'),
  spm('SR'),
  dps('DPS');

  final String label;
  const ChartMetric(this.label);
}

/// グラフの横軸。
enum ChartXAxis {
  time('時間'),
  distance('距離');

  final String label;
  const ChartXAxis(this.label);
}

/// 点 [i] の指標の値。練習の漕ぎ（500m=4:00より速い）のときだけ。
double? chartMetricValue(ReplayTrack track, int i, ChartMetric metric) {
  final v = track.speed[i];
  if (v < replayWorkSpeedMps) return null;
  return switch (metric) {
    ChartMetric.pace => 500 / v,
    ChartMetric.spm => track.spm[i],
    ChartMetric.dps => track.dpsAt(i),
  };
}

/// 横方向の拡大と移動（0〜1 の表示範囲）。
class ChartZoom {
  final double start;
  final double end;

  const ChartZoom(this.start, this.end);
  static const none = ChartZoom(0, 1);
  static const minSpan = 0.04;

  double get span => end - start;
  bool get isZoomed => span < 0.999;
  double get factor => 1 / span;

  /// 画面上の位置 [pivot]（0〜1）を中心に [factor] 倍する。
  ChartZoom scaledAround(double pivot, double factor) {
    final center = start + pivot * span;
    final ns = (span / factor).clamp(minSpan, 1.0);
    final s = (center - pivot * ns).clamp(0.0, 1.0 - ns);
    return ChartZoom(s, s + ns);
  }

  /// 表示幅に対する割合 [fraction] だけ動かす（正で右＝先の時刻へ）。
  ChartZoom panned(double fraction) {
    final s = (start + fraction * span).clamp(0.0, 1.0 - span);
    return ChartZoom(s, s + span);
  }

  @override
  bool operator ==(Object other) =>
      other is ChartZoom && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// グラフの1区画（1本・1区間）。横軸は本ごとに0から始める。
class ChartSegment {
  final ReplayRange range;

  /// 区画の長さ（時間 [秒] または距離 [m]）。
  final double length;
  final double x0;
  final double width;

  const ChartSegment({
    required this.range,
    required this.length,
    required this.x0,
    required this.width,
  });

  double get x1 => x0 + width;
}

/// グラフの横方向の配置。本と本の間は固定幅のすき間（レストの時間・距離を書く）。
class ChartLayout {
  final List<ChartSegment> segments;
  final ChartXAxis axis;
  final ReplayTrack track;

  /// 拡大後のすき間の幅 [px]。
  final double gapWidth;

  const ChartLayout._(this.segments, this.axis, this.track, this.gapWidth);

  factory ChartLayout.compute({
    required ReplayTrack track,
    required List<ReplayRange> ranges,
    required ChartXAxis axis,
    required double plotLeft,
    required double plotWidth,
    double gap = 34,
    ChartZoom zoom = ChartZoom.none,
  }) {
    final lengths = [
      for (final r in ranges)
        axis == ChartXAxis.time
            ? r.duration
            : math.max(
                1.0, track.distanceAt(r.end) - track.distanceAt(r.start)),
    ];
    final total = lengths.fold(0.0, (a, b) => a + b);
    final g = ranges.length > 1 ? gap : 0.0;
    final usable = plotWidth - g * (ranges.length - 1);
    final scale = 1 / zoom.span;
    var acc = 0.0;
    final segs = <ChartSegment>[];
    for (var k = 0; k < ranges.length; k++) {
      final x0 = plotLeft + (total > 0 ? acc / total * usable : 0) + k * g;
      final w = total > 0 ? lengths[k] / total * usable : 0.0;
      acc += lengths[k];
      segs.add(ChartSegment(
        range: ranges[k],
        length: lengths[k],
        x0: plotLeft +
            ((x0 - plotLeft) / plotWidth - zoom.start) * scale * plotWidth,
        width: w * scale,
      ));
    }
    return ChartLayout._(segs, axis, track, g * scale);
  }

  /// 区画の中での位置（時間なら区画の始まりからの秒、距離なら m）。
  double offsetOf(ChartSegment s, double time) => axis == ChartXAxis.time
      ? time - s.range.start
      : track.distanceAt(time) - track.distanceAt(s.range.start);

  double timeOfOffset(ChartSegment s, double offset) {
    if (axis == ChartXAxis.time) return s.range.start + offset;
    return track.timeAtDistance(
          track.distanceAt(s.range.start) + offset,
          track.indexAt(s.range.start),
          track.indexAt(s.range.end) + 1,
        ) ??
        s.range.end;
  }

  /// 時刻の画面上の位置。どの区画にも入らなければ null（レストの時刻など）。
  double? xOf(double time) {
    for (final s in segments) {
      if (s.range.contains(time)) {
        return s.x0 +
            offsetOf(s, time) / (s.length <= 0 ? 1 : s.length) * s.width;
      }
    }
    return null;
  }

  /// 画面上の位置 [x] の時刻。すき間では近い側の区画の端に寄せる。
  double timeAt(double x) {
    var seg = segments.first;
    for (final s in segments) {
      if (x >= s.x0 - gapWidth / 2) seg = s;
    }
    final off = ((x - seg.x0) / (seg.width <= 0 ? 1 : seg.width) * seg.length)
        .clamp(0.0, seg.length);
    return timeOfOffset(seg, off);
  }

  /// 画面上の位置 [x] にある区画（すき間なら null）。本のタップに使う。
  ChartSegment? segmentAt(double x) {
    for (final s in segments) {
      if (x >= s.x0 && x <= s.x1) return s;
    }
    return null;
  }
}

/// 横軸の目盛りの間隔。目盛りどうしが [minPixels] 以上あく「きりのよい」値。
double chartTickStep(double length, double width, ChartXAxis axis,
    {double minPixels = 30}) {
  const time = <double>[5, 10, 15, 20, 30, 60, 120, 300, 600, 900, 1200, 1800];
  const dist = <double>[25, 50, 100, 200, 250, 500, 1000, 2000, 5000];
  final steps = axis == ChartXAxis.time ? time : dist;
  for (final s in steps) {
    if (length > 0 && s / length * width >= minPixels) return s;
  }
  return steps.last;
}

/// 縦軸の範囲と目盛り。
class ChartYScale {
  final double low;
  final double high;
  final double step;

  const ChartYScale(this.low, this.high, this.step);

  int get tickCount => ((high - low) / step).round() + 1;
  List<double> get ticks =>
      [for (var k = 0; k < tickCount; k++) low + k * step];

  /// 目盛りが多いときは1つおきに数字を書く。
  int get labelEvery => tickCount > 8 ? 2 : 1;

  /// 練習として漕いでいる部分の値 [coreValues] から決める（設計書 §6.3a/§6.3b）。
  ///
  /// /500m: 上端=速い側2%、下端=そこから最大40秒（かつ遅い側10%まで）。
  /// SR・DPS: 5〜95パーセンタイル。範囲は目盛り（/500m は5秒）の倍数に外側へ丸める。
  static ChartYScale? fromValues(List<double> coreValues, ChartMetric metric) {
    if (coreValues.isEmpty) return null;
    final v = [...coreValues]..sort();
    double q(double p) => v[(v.length * p).floor().clamp(0, v.length - 1)];
    double lo, hi;
    if (metric == ChartMetric.pace) {
      lo = q(replayChartPaceFastQuantile);
      hi = math.min(
          q(replayChartPaceSlowQuantile), lo + replayChartPaceMaxSpanSec);
    } else {
      lo = q(replayChartOtherLowQuantile);
      hi = q(replayChartOtherHighQuantile);
    }
    final minWidth = switch (metric) {
      ChartMetric.pace => 6.0,
      ChartMetric.spm => 3.0,
      ChartMetric.dps => 0.6,
    };
    if (hi - lo < minWidth) {
      final m = (hi + lo) / 2;
      lo = m - minWidth / 2;
      hi = m + minWidth / 2;
    }
    final span = hi - lo;
    final step = switch (metric) {
      ChartMetric.pace => span <= 45 ? 5.0 : (span <= 90 ? 10.0 : 30.0),
      ChartMetric.spm => span <= 16 ? 2.0 : 4.0,
      ChartMetric.dps => span <= 4 ? 0.5 : 1.0,
    };
    lo = (lo / step - 1e-9).floor() * step;
    hi = (hi / step + 1e-9).ceil() * step;
    if (hi - lo < step * 2) hi = lo + step * 2;
    return ChartYScale(lo, hi, step);
  }
}
