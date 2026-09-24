import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../config/record_replay_config.dart';
import '../../../services/record/replay_track.dart';
import '../../../theme/record_palette.dart';
import '../replay_analysis.dart';
import '../replay_controller.dart';
import '../replay_format.dart';

/// 時間軸。なぞる=再生位置、タップ=セット（もう一度で本）、つまみ=区間の端、
/// 長押ししてからなぞる=その幅を区間にする。
class ReplayTimeline extends StatefulWidget {
  final ReplayController controller;
  const ReplayTimeline({super.key, required this.controller});

  @override
  State<ReplayTimeline> createState() => _ReplayTimelineState();
}

enum _Drag { none, scrub, handleStart, handleEnd }

class _ReplayTimelineState extends State<ReplayTimeline> {
  _Drag _drag = _Drag.none;
  double? _rangeAnchor;

  ReplayController get c => widget.controller;

  double _timeAt(double x, double width) {
    final v = c.timelineView;
    return (v.start + x / width * v.duration).clamp(v.start, v.end);
  }

  double _xOf(double t, double width) {
    final v = c.timelineView;
    return (t - v.start) / v.duration * width;
  }

  /// つまみをピースの端に吸い付ける（±6px 相当）。
  double _snap(double t, double width) {
    final tol = math.max(1.0, 6 * c.timelineView.duration / width);
    for (final s in c.analysis.sets) {
      for (final b in s.bouts) {
        if ((t - b.range.start).abs() < tol) return b.range.start;
        if ((t - b.range.end).abs() < tol) return b.range.end;
      }
    }
    return t;
  }

  @override
  Widget build(BuildContext context) {
    final p = RecordPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
      child: LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            c.pause();
            c.tapTimeline(_timeAt(d.localPosition.dx, w));
          },
          onLongPressStart: (d) {
            c.pause();
            _rangeAnchor = _timeAt(d.localPosition.dx, w);
            c.seek(_rangeAnchor!);
          },
          onLongPressMoveUpdate: (d) {
            final anchor = _rangeAnchor;
            if (anchor == null) return;
            final t = _timeAt(d.localPosition.dx, w);
            if ((t - anchor).abs() < 2) return;
            c.select(ReplayRange(math.min(anchor, t), math.max(anchor, t)),
                fitMap: false, cursorAt: t);
          },
          onLongPressEnd: (_) {
            if (_rangeAnchor != null && c.selection.duration >= 2) {
              c.select(c.selection);
            }
            _rangeAnchor = null;
          },
          onHorizontalDragStart: (d) {
            c.pause();
            final x = d.localPosition.dx;
            final sa = _xOf(c.selection.start, w),
                sb = _xOf(c.selection.end, w);
            if ((x - sa).abs() < 16 && (x - sa).abs() <= (x - sb).abs()) {
              _drag = _Drag.handleStart;
            } else if ((x - sb).abs() < 16) {
              _drag = _Drag.handleEnd;
            } else {
              _drag = _Drag.scrub;
              c.seek(_timeAt(x, w));
            }
          },
          onHorizontalDragUpdate: (d) {
            final t = _timeAt(d.localPosition.dx, w);
            switch (_drag) {
              case _Drag.scrub:
                c.seek(t);
              case _Drag.handleStart:
                c.select(
                    ReplayRange(math.min(_snap(t, w), c.selection.end - 2),
                        c.selection.end),
                    fitMap: false,
                    cursorAt: t);
              case _Drag.handleEnd:
                c.select(
                    ReplayRange(c.selection.start,
                        math.max(_snap(t, w), c.selection.start + 2)),
                    fitMap: false,
                    cursorAt: t);
              case _Drag.none:
                break;
            }
          },
          onHorizontalDragEnd: (_) {
            if (_drag == _Drag.handleStart || _drag == _Drag.handleEnd) {
              c.select(c.selection);
            }
            _drag = _Drag.none;
          },
          child: SizedBox(
            height: 62,
            width: w,
            child: CustomPaint(
              painter: _TimelinePainter(
                analysis: c.analysis,
                view: c.timelineView,
                selection: c.selection,
                cursor: c.cursor,
                palette: p,
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _TimelinePainter extends CustomPainter {
  final ReplayAnalysis analysis;
  final ReplayRange view;
  final ReplayRange selection;
  final double cursor;
  final RecordPalette palette;

  _TimelinePainter({
    required this.analysis,
    required this.view,
    required this.selection,
    required this.cursor,
    required this.palette,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final p = palette;
    final w = size.width;
    const y0 = 10.0, hh = 30.0;
    double x(double t) => (t - view.start) / view.duration * w;
    final bar = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, y0, w, hh), const Radius.circular(9));
    canvas.drawRRect(bar, Paint()..color = p.surfaceHigh);
    if (view.duration <= 0 || analysis.track.length < 2) return;

    canvas.save();
    canvas.clipRRect(bar);
    final tr = analysis.track;
    final i0 = tr.indexAt(view.start);
    final i1 = math.min(tr.length - 1, tr.indexAt(view.end) + 1);
    final paint = Paint();
    for (var i = math.max(1, i0); i <= i1; i++) {
      final x0 = x(tr.t[i - 1]), x1 = x(tr.t[i]);
      if (x1 < 0 || x0 > w) continue;
      final v = tr.speed[i];
      if (v < replayMovingSpeedMps) continue;
      final ww = math.max(0.6, x1 - x0 + 0.4);
      if (v < replayWorkSpeedMps) {
        paint.color = p.surfaceHigher;
        canvas.drawRect(Rect.fromLTWH(x0, y0 + hh / 2 - 3, ww, 6), paint);
      } else if (!analysis.inBout[i]) {
        paint.color = p.surfaceHigher;
        canvas.drawRect(Rect.fromLTWH(x0, y0 + hh / 2 - 5, ww, 10), paint);
      } else {
        paint.color = RecordPalette.paceRamp(analysis.paceRatio(500 / v));
        canvas.drawRect(Rect.fromLTWH(x0, y0 + 4, ww, hh - 8), paint);
      }
    }
    canvas.restore();

    // セットの範囲（下の細い帯、色=強度）
    for (final s in analysis.sets) {
      final a = x(s.range.start), b = x(s.range.end);
      if (b < 0 || a > w) continue;
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTRB(
                  math.max(0, a), y0 + hh + 1, math.min(w, b), y0 + hh + 4),
              const Radius.circular(1.5)),
          Paint()
            ..color = p.intensity(s.intensity.index).withValues(alpha: 0.85));
    }

    // 選択区間（外は暗く、枠とつまみ）
    final sa = x(selection.start), sb = x(selection.end);
    final shade = Paint()..color = p.background.withValues(alpha: 0.6);
    canvas.drawRect(Rect.fromLTWH(0, y0, math.max(0, sa), hh), shade);
    canvas.drawRect(Rect.fromLTWH(sb, y0, math.max(0, w - sb), hh), shade);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTRB(sa, y0 - 2, math.max(sa + 2, sb), y0 + hh + 2),
            const Radius.circular(8)),
        Paint()
          ..color = p.accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5);
    for (final (hx, off) in [(sa, -9.0), (sb, -1.0)]) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(hx + off, y0 - 2, 10, hh + 4),
              const Radius.circular(5)),
          Paint()..color = p.accent);
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(hx + off + 4, y0 + hh / 2 - 6, 2, 12),
              const Radius.circular(1)),
          Paint()..color = p.onAccent);
    }

    // 目盛り
    final span = view.duration;
    final step = span > 5400
        ? 900.0
        : span > 2400
            ? 600.0
            : span > 1200
                ? 300.0
                : span > 480
                    ? 60.0
                    : span > 150
                        ? 30.0
                        : 10.0;
    for (var s = (view.start / step).ceil() * step;
        s <= view.end + 0.1;
        s += step) {
      final tx = x(s);
      final label = step >= 60 ? '${(s / 60).round()}分' : fmtDuration(s);
      final tp = TextPainter(
        text: TextSpan(
            text: label,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700, color: p.textMute)),
        textDirection: TextDirection.ltr,
      )..layout();
      final left = (tx - tp.width / 2).clamp(0.0, w - tp.width);
      tp.paint(canvas, Offset(left, size.height - tp.height));
    }

    // 再生位置
    final cx = x(cursor);
    if (cx >= -2 && cx <= w + 2) {
      final cp = Paint()
        ..color = p.cursor
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(cx, y0 - 5), Offset(cx, y0 + hh + 4), cp);
      canvas.drawCircle(Offset(cx, y0 - 6), 4.5, Paint()..color = p.cursor);
    }
  }

  @override
  bool shouldRepaint(_TimelinePainter old) =>
      old.cursor != cursor ||
      old.selection != selection ||
      old.view != view ||
      old.palette != palette ||
      old.analysis != analysis;
}
