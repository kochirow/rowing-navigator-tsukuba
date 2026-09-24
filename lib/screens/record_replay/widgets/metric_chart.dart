import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/record/record_chart_model.dart';
import '../../../services/record/replay_track.dart';
import '../../../services/record/training_set_detector.dart';
import '../../../theme/record_palette.dart';
import '../replay_controller.dart';
import '../replay_format.dart';
import 'selection_card.dart';

const _plotLeft = 40.0;
const _plotRight = 6.0;
const _chartHeight = 206.0;

/// 推移グラフ（1枚だけ。指標と横軸を切り替える）。
class MetricChartCard extends StatelessWidget {
  final ReplayController controller;
  const MetricChartCard({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final p = RecordPalette.of(context);
    final c = controller;
    final bout = c.selectedBout;
    final parent = bout == null ? null : c.analysis.sets[bout.setIndex];
    return RecordCard(
      palette: p,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('推移',
            style: TextStyle(
                fontSize: 11,
                letterSpacing: 1,
                fontWeight: FontWeight.w800,
                color: p.textSub)),
        const SizedBox(height: 10),
        _Segmented<ChartMetric>(
          palette: p,
          values: ChartMetric.values,
          selected: c.metric,
          label: (m) => m.label,
          color: (m) => switch (m) {
            ChartMetric.pace => p.metricPace,
            ChartMetric.spm => p.metricSpm,
            ChartMetric.dps => p.metricDps,
          },
          onChanged: c.setMetric,
        ),
        if (parent != null && parent.bouts.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: GestureDetector(
              onTap: () => c.selectSet(parent),
              child: Text('‹ ${parent.index + 1}セット目の全体に戻る',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: p.accent)),
            ),
          ),
        const SizedBox(height: 10),
        MetricChart(controller: c),
        const SizedBox(height: 6),
        Row(children: [
          const Spacer(),
          Text('横軸',
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: p.textSub)),
          const SizedBox(width: 8),
          SizedBox(
            width: 140,
            child: _Segmented<ChartXAxis>(
              palette: p,
              values: ChartXAxis.values,
              selected: c.axis,
              label: (a) => a.label,
              onChanged: c.setAxis,
              height: 30,
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Text(
          [
            if (c.chartRanges.length > 1)
              'レストを詰めて、漕いだ部分だけを並べています。本をタップするとその本を拡大します。',
            if (c.metric == ChartMetric.pace) '上が速い。',
            '縦軸は練習中のタイムに合わせているので、遅いパドルなどは下端に張り付きます。',
          ].join(''),
          style: TextStyle(fontSize: 12, height: 1.5, color: p.textSub),
        ),
      ]),
    );
  }
}

/// グラフ本体。
///
/// - タップ: 再生位置。2本以上のセットでは、その本を選んで拡大する
/// - 左右のなぞり: 再生位置（拡大中は表示を左右に動かす）
/// - 2本指のピンチ: 横軸の拡大縮小。ダブルタップで元に戻す
///
/// ピンチは指の本数を直接見て扱う（ジェスチャーの取り合いに参加しない）。
/// ページの縦スクロールを奪わないため。
class MetricChart extends StatefulWidget {
  final ReplayController controller;
  const MetricChart({super.key, required this.controller});

  @override
  State<MetricChart> createState() => _MetricChartState();
}

class _MetricChartState extends State<MetricChart> {
  final Map<int, Offset> _pointers = {};
  double? _pinchStartDistance;
  double _pinchStartMid = 0;
  ChartZoom _pinchStartZoom = ChartZoom.none;
  DateTime? _lastTapAt;

  ReplayController get c => widget.controller;
  bool get _pinching => _pointers.length >= 2;

  ChartLayout _layout(double width) => ChartLayout.compute(
        track: c.track,
        ranges: c.chartRanges,
        axis: c.axis,
        plotLeft: _plotLeft,
        plotWidth: width - _plotLeft - _plotRight,
        zoom: c.zoom,
      );

  void _onPointerDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length == 2) {
      final ps = _pointers.values.toList();
      _pinchStartDistance = math.max(1, (ps[0].dx - ps[1].dx).abs());
      _pinchStartMid = (ps[0].dx + ps[1].dx) / 2;
      _pinchStartZoom = c.zoom;
      c.pause();
    }
  }

  void _onPointerMove(PointerMoveEvent e, double width) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    if (!_pinching || _pinchStartDistance == null) return;
    final ps = _pointers.values.take(2).toList();
    final d = math.max(1.0, (ps[0].dx - ps[1].dx).abs());
    final mid = (ps[0].dx + ps[1].dx) / 2;
    final plot = width - _plotLeft - _plotRight;
    // 指を置いた位置の時刻が、指の中点についてくるように拡大・移動する
    final z0 = _pinchStartZoom;
    final pivot0 = ((_pinchStartMid - _plotLeft) / plot).clamp(0.0, 1.0);
    final anchor = z0.start + pivot0 * z0.span;
    final span =
        (z0.span * _pinchStartDistance! / d).clamp(ChartZoom.minSpan, 1.0);
    final pivot = ((mid - _plotLeft) / plot).clamp(0.0, 1.0);
    final start = (anchor - pivot * span).clamp(0.0, 1.0 - span);
    c.setZoom(ChartZoom(start, start + span));
  }

  void _onPointerUp(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.length < 2) _pinchStartDistance = null;
  }

  @override
  Widget build(BuildContext context) {
    final p = RecordPalette.of(context);
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      final layout = _layout(w);
      final plot = w - _plotLeft - _plotRight;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: (e) => _onPointerMove(e, w),
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerUp,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              c.pause();
              final now = DateTime.now();
              final isDouble = _lastTapAt != null &&
                  now.difference(_lastTapAt!) <
                      const Duration(milliseconds: 320);
              _lastTapAt = now;
              if (isDouble && c.zoom.isZoomed) {
                c.setZoom(ChartZoom.none);
                _lastTapAt = null;
                return;
              }
              final x = d.localPosition.dx;
              final set = c.selectedSet;
              final seg = layout.segmentAt(x);
              if (set != null && set.bouts.length > 1 && seg != null) {
                final bout = set.bouts.firstWhere((b) => b.range == seg.range);
                c.selectBout(bout, cursorAt: layout.timeAt(x));
              } else {
                c.seek(layout.timeAt(x));
              }
            },
            onHorizontalDragStart: (_) => c.pause(),
            onHorizontalDragUpdate: (d) {
              if (_pinching) return;
              if (c.zoom.isZoomed) {
                c.setZoom(c.zoom.panned(-d.delta.dx / plot));
              } else {
                c.seek(layout.timeAt(d.localPosition.dx));
              }
            },
            child: SizedBox(
              height: _chartHeight,
              width: w,
              child: CustomPaint(
                painter:
                    _ChartPainter(controller: c, layout: layout, palette: p),
              ),
            ),
          ),
        ),
        if (c.zoom.isZoomed) ...[
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: _plotLeft, right: _plotRight),
            child: _ZoomBar(controller: c, palette: p, width: plot),
          ),
        ],
        const SizedBox(height: 4),
        Text.rich(
          TextSpan(children: [
            TextSpan(
                text: c.zoom.isZoomed
                    ? '拡大 ×${c.zoom.factor.toStringAsFixed(1)} ・ 左右になぞるか下のバーで移動  '
                    : '2本指で広げると拡大'),
            if (c.zoom.isZoomed)
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: GestureDetector(
                  onTap: () => c.setZoom(ChartZoom.none),
                  child: Text('元に戻す',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: p.accent)),
                ),
              ),
          ]),
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: p.textMute),
        ),
      ]);
    });
  }
}

/// 拡大中の表示範囲を示し、ドラッグで動かせるバー。
class _ZoomBar extends StatelessWidget {
  final ReplayController controller;
  final RecordPalette palette;
  final double width;
  const _ZoomBar(
      {required this.controller, required this.palette, required this.width});

  @override
  Widget build(BuildContext context) {
    final z = controller.zoom;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (d) =>
          controller.setZoom(z.panned(d.delta.dx / width / z.span)),
      child: SizedBox(
        height: 18,
        child: Stack(children: [
          Positioned(
            left: 0,
            right: 0,
            top: 7,
            height: 4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                  color: palette.surfaceHigh,
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),
          Positioned(
            left: z.start * width,
            width: math.max(12, z.span * width),
            top: 3,
            height: 12,
            child: DecoratedBox(
              decoration: BoxDecoration(
                  color: palette.accent.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(6)),
            ),
          ),
        ]),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  final ReplayController controller;
  final ChartLayout layout;
  final RecordPalette palette;

  _ChartPainter(
      {required this.controller, required this.layout, required this.palette});

  static const pt = 20.0, pb = 38.0;

  void _text(Canvas canvas, String s, Offset at, TextStyle style,
      {TextAlign align = TextAlign.left}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = switch (align) {
      TextAlign.center => at.dx - tp.width / 2,
      TextAlign.right => at.dx - tp.width,
      _ => at.dx,
    };
    tp.paint(canvas, Offset(dx, at.dy - tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final p = palette;
    final c = controller;
    final tr = c.track;
    final metric = c.metric;
    final w = size.width, h = size.height;
    final base = h - pb;
    final set = c.selectedSet;
    final multi = layout.segments.length > 1;
    final lineColor = switch (metric) {
      ChartMetric.pace => p.metricPace,
      ChartMetric.spm => p.metricSpm,
      ChartMetric.dps => p.metricDps,
    };
    final sub =
        TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: p.textMute);
    final bold =
        TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: p.text);

    // 各区画の点と、縦軸の範囲を決める値
    final pts = <List<(double, double?)>>[];
    final core = <double>[], all = <double>[];
    for (final s in layout.segments) {
      final seg = <(double, double?)>[];
      for (var i = tr.indexAt(s.range.start);
          i <= math.min(tr.length - 1, tr.indexAt(s.range.end) + 1);
          i++) {
        final t = tr.t[i];
        if (t < s.range.start || t > s.range.end) continue;
        final inWork = set != null || c.analysis.inBout[i];
        final v = inWork || !multi ? chartMetricValue(tr, i, metric) : null;
        seg.add((
          s.x0 + layout.offsetOf(s, t) / math.max(1e-9, s.length) * s.width,
          v
        ));
        if (v == null) continue;
        all.add(v);
        if (inWork &&
            t - s.range.start >= 8 &&
            s.range.end - t >= 8 &&
            (set != null || c.analysis.inBout[i])) {
          core.add(v);
        }
      }
      pts.add(seg);
    }
    final scale = ChartYScale.fromValues(core.length >= 8 ? core : all, metric);
    if (scale == null) {
      _text(canvas, 'この区間には漕いでいる時間がありません', Offset(w / 2, h / 2),
          TextStyle(fontSize: 13, color: p.textMute),
          align: TextAlign.center);
      return;
    }
    final inv = metric == ChartMetric.pace;
    double y(double v) {
      final r = ((v.clamp(scale.low, scale.high) - scale.low) /
          (scale.high - scale.low));
      return pt + (inv ? r : 1 - r) * (base - pt);
    }

    String fmtV(double v) => switch (metric) {
          ChartMetric.pace => fmtPace(v),
          ChartMetric.spm => '${v.round()}',
          ChartMetric.dps => v.toStringAsFixed(scale.step < 1 ? 1 : 0),
        };

    // 縦軸の目盛り
    final grid = Paint()
      ..color = p.line
      ..strokeWidth = 1;
    final ticks = scale.ticks;
    for (var k = 0; k < ticks.length; k++) {
      final yy = y(ticks[k]);
      for (var xx = _plotLeft; xx < w - _plotRight; xx += 6) {
        canvas.drawLine(
            Offset(xx, yy), Offset(math.min(xx + 2, w - _plotRight), yy), grid);
      }
      if (k % scale.labelEvery == 0) {
        _text(canvas, fmtV(ticks[k]), Offset(_plotLeft - 6, yy), sub,
            align: TextAlign.right);
      }
    }

    canvas.save();
    canvas.clipRect(
        Rect.fromLTWH(_plotLeft - 1, 0, w - _plotLeft - _plotRight + 2, h));
    final segs = layout.segments;
    for (var k = 0; k < segs.length; k++) {
      final s = segs[k];
      // レストのすき間
      if (k > 0) {
        final prev = segs[k - 1];
        final gx = prev.x1, gw = s.x0 - gx;
        canvas.drawRRect(
            RRect.fromRectAndRadius(
                Rect.fromLTWH(gx + 3, pt, gw - 6, base - pt),
                const Radius.circular(4)),
            Paint()..color = p.surfaceHigh);
        final gap = ReplayRange(prev.range.end, s.range.start);
        final kind = c.analysis.gapKind(gap).label;
        final isHigh = set?.intensity == TrainingIntensity.highRate;
        final cx = gx + gw / 2;
        if (isHigh) {
          _text(canvas, 'レスト', Offset(cx, base - 41), sub,
              align: TextAlign.center);
        }
        _text(canvas, kind, Offset(cx, base - 30), sub,
            align: TextAlign.center);
        _text(canvas, fmtDuration(gap.duration), Offset(cx, base - 18), bold,
            align: TextAlign.center);
        _text(
            canvas,
            '${(tr.distanceAt(gap.end) - tr.distanceAt(gap.start)).round()}m',
            Offset(cx, base - 7),
            sub,
            align: TextAlign.center);
      }
      // 横軸の目盛り（本ごとに0から、右端に長さ）
      final dist = layout.axis == ChartXAxis.distance;
      final endLabel = dist ? '${s.length.round()}' : fmtDuration(s.length);
      final endW = endLabel.length * 5.6;
      canvas.drawLine(Offset(s.x1, base), Offset(s.x1, base + 4),
          Paint()..color = p.textMute);
      _text(canvas, endLabel, Offset(s.x1, base + 12), bold,
          align: TextAlign.right);
      final step = chartTickStep(s.length, s.width, layout.axis);
      for (var u = 0.0; u <= s.length + 0.01; u += step) {
        final xx = s.x0 + u / math.max(1e-9, s.length) * s.width;
        if (s.x1 - xx < endW + 10) continue;
        canvas.drawLine(Offset(xx, base), Offset(xx, base + 4),
            Paint()..color = p.textMute);
        _text(canvas, u == 0 ? '0' : (dist ? '${u.round()}' : fmtDuration(u)),
            Offset(xx, base + 12), sub,
            align: u == 0 ? TextAlign.left : TextAlign.center);
      }
      if (multi && set != null) {
        _text(
            canvas,
            s.width > 44 ? '${k + 1}${set.intensity.unit}目' : '${k + 1}',
            Offset(s.x0 + s.width / 2, pt - 8),
            sub,
            align: TextAlign.center);
      }
      // 線と塗り（値の無い点・12秒以上の欠けで線を切る）
      final runs = <List<Offset>>[];
      var run = <Offset>[];
      double? lastX;
      for (final (px, v) in pts[k]) {
        final tooFar = lastX != null &&
            layout.axis == ChartXAxis.time &&
            (px - lastX) / math.max(1e-9, s.width) * s.length > 12;
        if (v == null || tooFar) {
          if (run.length > 1) runs.add(run);
          run = <Offset>[];
          if (v == null) {
            lastX = null;
            continue;
          }
        }
        run.add(Offset(px, y(v)));
        lastX = px;
      }
      if (run.length > 1) runs.add(run);
      final fillPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            lineColor.withValues(alpha: 0.38),
            lineColor.withValues(alpha: 0)
          ],
        ).createShader(Rect.fromLTWH(0, pt, w, base - pt));
      final strokePaint = Paint()
        ..color = lineColor
        ..strokeWidth = 2.2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      for (final r in runs) {
        final line = Path()..addPolygon(r, false);
        final fill = Path()
          ..addPolygon(
              [...r, Offset(r.last.dx, base), Offset(r.first.dx, base)], true);
        canvas.drawPath(fill, fillPaint);
        canvas.drawPath(line, strokePaint);
      }
    }
    canvas.restore();
    canvas.drawLine(
        Offset(_plotLeft, base), Offset(w - _plotRight, base), grid);

    // 平均の線
    final st = c.selectionStats;
    final avg = switch (metric) {
      ChartMetric.pace => st.paceSecPer500,
      ChartMetric.spm => st.averageSpm,
      ChartMetric.dps => st.averageDps,
    };
    if (avg != null) {
      final yy = y(avg);
      final dash = Paint()
        ..color = p.text.withValues(alpha: 0.5)
        ..strokeWidth = 1;
      for (var xx = _plotLeft; xx < w - _plotRight; xx += 9) {
        canvas.drawLine(
            Offset(xx, yy), Offset(math.min(xx + 5, w - _plotRight), yy), dash);
      }
      final label = '平均 ${fmtV(avg)}';
      final lw = label.length * 6.4 + 12;
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(w - _plotRight - lw, yy - 8, lw, 16),
              const Radius.circular(8)),
          Paint()..color = p.surfaceHigher);
      _text(canvas, label, Offset(w - _plotRight - lw / 2, yy), bold,
          align: TextAlign.center);
    }

    // 再生位置
    final cx = layout.xOf(c.cursor);
    if (cx != null && cx >= _plotLeft && cx <= w - _plotRight) {
      canvas.drawLine(
          Offset(cx, pt - 2),
          Offset(cx, base),
          Paint()
            ..color = p.cursor
            ..strokeWidth = 1.5);
      final ci = tr.indexAt(c.cursor);
      final cv = chartMetricValue(tr, ci, metric);
      if (cv != null) {
        canvas.drawCircle(Offset(cx, y(cv)), 5, Paint()..color = p.cursor);
        final label = fmtV(cv);
        final bw = label.length * 7.0 + 16;
        final bx = (cx - bw / 2).clamp(_plotLeft, w - _plotRight - bw);
        canvas.drawRRect(
            RRect.fromRectAndRadius(
                Rect.fromLTWH(bx, 0, bw, 17), const Radius.circular(8.5)),
            Paint()..color = p.cursor);
        _text(
            canvas,
            label,
            Offset(bx + bw / 2, 8.5),
            const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                color: Colors.white),
            align: TextAlign.center);
      }
    }
    _text(
        canvas,
        layout.axis == ChartXAxis.distance ? 'm（本ごとに0から）' : '分:秒（本ごとに0から）',
        Offset(w - _plotRight, h - 5),
        sub,
        align: TextAlign.right);
  }

  @override
  bool shouldRepaint(_ChartPainter old) => true;
}

/// 小さな切替ボタンの並び。
class _Segmented<T> extends StatelessWidget {
  final RecordPalette palette;
  final List<T> values;
  final T selected;
  final String Function(T) label;
  final Color Function(T)? color;
  final ValueChanged<T> onChanged;
  final double height;

  const _Segmented({
    required this.palette,
    required this.values,
    required this.selected,
    required this.label,
    required this.onChanged,
    this.color,
    this.height = 36,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
          color: p.surfaceHigh, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        for (final v in values)
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(v),
              child: Container(
                height: height,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: v == selected ? p.surfaceHigher : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(label(v),
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: v == selected
                            ? (color?.call(v) ?? p.text)
                            : p.textSub)),
              ),
            ),
          ),
      ]),
    );
  }
}
