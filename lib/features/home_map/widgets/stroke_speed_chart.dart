import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../config/stroke_trace_config.dart';
import '../../../services/stroke_speed_trace.dart';
import '../../../theme/app_theme.dart';

/// 艇速の時間変化を、心電図のように左へ流しながら描く。
///
/// 縦軸=艇速、横軸=時間。**直近2ストロークが常に画面に入る**ように、
/// 時間窓はSPMから決める(遅く漕げば窓は広がる)。
///
/// 表示の作り:
///   - 右端が「いま」。新しい点が右から入り、古い点が左へ流れて消える
///   - 縦の細い線がキャッチ(ストローク境界)。2本見えていれば2ストローク
///   - 破線が窓の平均艇速。線がその上にあるあいだが「速い区間」
///   - 右肩の数字が窓内の最高・最低艇速
///
/// **性能上の約束**: このウィジェットは再buildされない。時間の進みは
/// [Ticker] から [_StrokeChartModel] へ入り、[CustomPaint] の repaint
/// だけを起こす。描く点は1画面あたり150〜250点で、Pathは1本。
///
/// **表示専用。** ここに出る値は安全判定にも他艇へも一切渡らない。
class StrokeSpeedChart extends StatefulWidget {
  /// 描画時刻を渡すと、その時点の窓を返す。null なら「まだ描けない」。
  final StrokeSpeedTraceWindow? Function(DateTime now) windowBuilder;

  /// 時間を進め続けるか。false のあいだ Ticker を止める(電池)。
  final bool live;

  final double height;

  /// 濃色スクリム(航行計器カード)の上か、明色カード(監視シート)の上か。
  final bool onDarkSurface;

  /// データが無いときに出す一言。理由は呼出元が知っている。
  final String emptyLabel;

  const StrokeSpeedChart({
    super.key,
    required this.windowBuilder,
    this.live = true,
    this.height = 78,
    this.onDarkSurface = true,
    this.emptyLabel = '波形を計測中',
  });

  @override
  State<StrokeSpeedChart> createState() => _StrokeSpeedChartState();
}

class _StrokeSpeedChartState extends State<StrokeSpeedChart>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _model = _StrokeChartModel();
  Duration _lastFrame = Duration.zero;

  static const _frameInterval =
      Duration(microseconds: 1000000 ~/ strokeTraceRepaintHz);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _sync();
  }

  @override
  void didUpdateWidget(covariant StrokeSpeedChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.live && !_ticker.isActive) {
      _lastFrame = Duration.zero;
      _ticker.start();
    } else if (!widget.live && _ticker.isActive) {
      _ticker.stop();
    }
    // 停止中でも1回は最新状態を取り込む(切替直後の空白を作らない)。
    if (!widget.live) _model.update(widget.windowBuilder(DateTime.now()));
  }

  void _onTick(Duration elapsed) {
    // 25Hzで十分。60fpsで引き直しても、記録が25Hzなので絵は変わらない。
    if (elapsed - _lastFrame < _frameInterval) return;
    _lastFrame = elapsed;
    _model.update(widget.windowBuilder(DateTime.now()));
  }

  @override
  void dispose() {
    _ticker.dispose();
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final foreground =
        widget.onDarkSurface ? colors.onDark : colors.textPrimary;
    final accent =
        widget.onDarkSurface ? colors.primaryLight : colors.primary;
    return RepaintBoundary(
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: CustomPaint(
          painter: _StrokeSpeedChartPainter(
            model: _model,
            foreground: foreground,
            accent: accent,
            emptyLabel: widget.emptyLabel,
            textDirection: Directionality.of(context),
          ),
        ),
      ),
    );
  }
}

/// 窓と縦軸スケールを持ち、変化したときだけ再描画を要求する。
///
/// 縦軸を毎フレーム実測へ合わせると、波が上下するたびに軸ごと動いて
/// 何も読めなくなる。目標値へ緩やかに寄せ、下限レンジを必ず確保する。
class _StrokeChartModel extends ChangeNotifier {
  StrokeSpeedTraceWindow? window;
  double scaleMin = 0;
  double scaleMax = 1;
  bool _hasScale = false;

  void update(StrokeSpeedTraceWindow? next) {
    window = next;
    if (next != null && !next.isEmpty) {
      final span = math.max(
        next.maxSpeed - next.minSpeed,
        strokeTraceMinimumSpanMetersPerSecond,
      );
      final padding = span * strokeTraceVerticalPaddingFraction;
      final center = (next.maxSpeed + next.minSpeed) / 2;
      final targetMin = math.max(0.0, center - span / 2 - padding);
      final targetMax = center + span / 2 + padding;
      if (!_hasScale) {
        scaleMin = targetMin;
        scaleMax = targetMax;
        _hasScale = true;
      } else {
        // 1フレームあたり12%ずつ寄せる。約0.5秒で追従し、
        // 1ストローク内の上下では軸が動かない。
        scaleMin += (targetMin - scaleMin) * 0.12;
        scaleMax += (targetMax - scaleMax) * 0.12;
      }
    }
    notifyListeners();
  }
}

class _StrokeSpeedChartPainter extends CustomPainter {
  final _StrokeChartModel model;
  final Color foreground;
  final Color accent;
  final String emptyLabel;
  final TextDirection textDirection;

  _StrokeSpeedChartPainter({
    required this.model,
    required this.foreground,
    required this.accent,
    required this.emptyLabel,
    required this.textDirection,
  }) : super(repaint: model);

  @override
  void paint(Canvas canvas, Size size) {
    final radius = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(10),
    );
    canvas.drawRRect(
      radius,
      Paint()..color = foreground.withValues(alpha: 0.06),
    );

    final window = model.window;
    if (window == null || window.isEmpty || window.length < 2) {
      _paintLabel(canvas, size, emptyLabel);
      return;
    }

    canvas.save();
    canvas.clipRRect(radius);

    // 右端に数値を置くぶんだけ描画領域を空ける。
    const rightGutter = 46.0;
    final plotWidth = math.max(1.0, size.width - rightGutter);
    final spanMs = math.max(1.0, window.endMs - window.startMs);
    final range = math.max(1e-3, model.scaleMax - model.scaleMin);

    double dx(double timeMs) => (timeMs - window.startMs) / spanMs * plotWidth;
    double dy(double speed) =>
        size.height -
        ((speed - model.scaleMin) / range).clamp(0.0, 1.0) * size.height;

    // ---- キャッチ(ストローク境界) ----
    final catchPaint = Paint()
      ..color = foreground.withValues(alpha: 0.28)
      ..strokeWidth = 1;
    for (final catchMs in window.catchTimesMs) {
      final x = dx(catchMs);
      if (x < 0 || x > plotWidth) continue;
      canvas.drawLine(Offset(x, 4), Offset(x, size.height - 4), catchPaint);
    }

    // ---- 平均艇速の基準線 ----
    final meanY = dy(window.meanSpeed);
    final dashPaint = Paint()
      ..color = foreground.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (var x = 0.0; x < plotWidth; x += 7) {
      canvas.drawLine(Offset(x, meanY), Offset(x + 3.5, meanY), dashPaint);
    }

    // ---- 波形 ----
    final line = Path();
    final fill = Path();
    var started = false;
    var lastX = 0.0;
    var firstX = 0.0;
    for (var index = 0; index < window.length; index++) {
      final x = dx(window.timesMs[index]);
      final y = dy(window.speeds[index]);
      if (!started) {
        line.moveTo(x, y);
        fill.moveTo(x, size.height);
        fill.lineTo(x, y);
        firstX = x;
        started = true;
      } else {
        line.lineTo(x, y);
        fill.lineTo(x, y);
      }
      lastX = x;
    }
    fill.lineTo(lastX, size.height);
    fill.lineTo(firstX, size.height);
    fill.close();

    canvas.drawPath(
      fill,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, 0),
          Offset(0, size.height),
          [
            accent.withValues(alpha: 0.34),
            accent.withValues(alpha: 0.02),
          ],
        ),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );

    // ---- 先頭(いま)の点 ----
    // データが右端まで届いていないときは、届いた所で止める。
    // 空白を線で埋めない(欠測を「変化なし」と読ませない)。
    final headY = dy(window.speeds[window.length - 1]);
    canvas.drawCircle(
      Offset(lastX, headY),
      3.2,
      Paint()..color = accent,
    );
    canvas.drawCircle(
      Offset(lastX, headY),
      6.5,
      Paint()..color = accent.withValues(alpha: 0.22),
    );

    canvas.restore();

    // ---- 右肩の目盛り ----
    _paintScaleLabel(
      canvas,
      Offset(size.width - 4, 2),
      model.scaleMax.toStringAsFixed(1),
    );
    _paintScaleLabel(
      canvas,
      Offset(size.width - 4, size.height - 15),
      '${model.scaleMin.toStringAsFixed(1)} m/s',
    );
  }

  void _paintScaleLabel(Canvas canvas, Offset topRight, String text) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: foreground.withValues(alpha: 0.62),
          fontSize: 10,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: textDirection,
    )..layout();
    painter.paint(canvas, Offset(topRight.dx - painter.width, topRight.dy));
  }

  void _paintLabel(Canvas canvas, Size size, String text) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: foreground.withValues(alpha: 0.6),
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: textDirection,
    )..layout(maxWidth: size.width - 16);
    painter.paint(
      canvas,
      Offset(
        (size.width - painter.width) / 2,
        (size.height - painter.height) / 2,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant _StrokeSpeedChartPainter oldDelegate) =>
      oldDelegate.foreground != foreground ||
      oldDelegate.accent != accent ||
      oldDelegate.emptyLabel != emptyLabel;
}
