import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../config/map_style_config.dart';
import '../../../models/navigation_warning.dart';
import '../../../models/safety_snapshot.dart';
import '../../../theme/nav_palette.dart';

/// 画面の縁を光らせる警告の中身。[screenAngleDegrees] が null なら向き不明。
class EdgeAlert {
  const EdgeAlert({required this.warning, this.screenAngleDegrees});

  final NavigationWarning warning;

  /// 画面上の角度(上=0、時計回り)。
  final double? screenAngleDegrees;
}

/// 案内(衝突ではない)なので縁を光らせない種類。
const _guidanceCategories = {'curve', 'reverse'};

/// 縁を光らせるかを決める(表示専用・新しい判定は持たない)。
///
/// **規則は1つ: 衝突の音が鳴っているときだけ、音の元の方角の縁を光らせる。**
/// 音の有無は `SafetySnapshot.audioDirective` がそのまま決める
/// (停止中の固定障害物の抑制・表示のみの候補・system fault はここに来ない)。
/// カーブ・逆走の読み上げは案内なので光らせない。陸上判定中は音を止めるので光らせない。
///
/// 方角は `NavigationWarning.relativeBearingDegrees`(方位が信頼できるときだけ入る。
/// 不変条件10)。地図は進行方位+180度で回すので、画面角 = 180 + 相対方位。
/// 画面の位置がそのまま漕手の体から見た向きになる(右後ろ=画面の右下)。
EdgeAlert? edgeAlertFor({
  required AudioDirective? directive,
  required List<NavigationWarning> warnings,
  required bool ashore,
}) {
  if (directive == null || ashore) return null;
  NavigationWarning? warning;
  for (final w in warnings) {
    if (w.key == directive.alertId) {
      warning = w;
      break;
    }
  }
  if (warning == null || _guidanceCategories.contains(warning.category)) {
    return null;
  }
  final bearing = warning.relativeBearingDegrees;
  return EdgeAlert(
    warning: warning,
    screenAngleDegrees:
        bearing == null || !bearing.isFinite ? null : (180 + bearing) % 360,
  );
}

/// 自艇([self])から [screenAngleDegrees] の向きへ伸ばした線が、[size] の
/// 縁に当たる点。
Offset edgeAnchorFor(double screenAngleDegrees, Size size, Offset self) {
  final rad = screenAngleDegrees * math.pi / 180;
  final dx = math.sin(rad), dy = -math.cos(rad);
  var t = double.infinity;
  if (dx > 1e-9) t = math.min(t, (size.width - self.dx) / dx);
  if (dx < -1e-9) t = math.min(t, -self.dx / dx);
  if (dy > 1e-9) t = math.min(t, (size.height - self.dy) / dy);
  if (dy < -1e-9) t = math.min(t, -self.dy / dy);
  return Offset(self.dx + dx * t, self.dy + dy * t);
}

/// 警告の方角の画面の縁を赤く点滅させる(1Hz)。予告と本警告で見た目を分けない。
///
/// 触れない(`IgnorePointer`)。読み上げ用に、見えない `liveRegion` を残す
/// (大きな警告バナーは画面から外した。警告は音で聞かせるもの)。
class EdgeAlertOverlay extends StatefulWidget {
  const EdgeAlertOverlay({super.key, required this.alert});

  final EdgeAlert? alert;

  @override
  State<EdgeAlertOverlay> createState() => _EdgeAlertOverlayState();
}

class _EdgeAlertOverlayState extends State<EdgeAlertOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant EdgeAlertOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.alert == null) {
      if (_pulse.isAnimating) _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final alert = widget.alert;
    if (alert == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Semantics(
            liveRegion: true,
            label: alert.warning.title,
            child: const SizedBox.shrink(),
          ),
          AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) {
              // 0→1 の間で明→暗→明(三角波)。
              final t = _pulse.value;
              final strength = 0.35 + 0.65 * (1 - (2 * t - 1).abs());
              return CustomPaint(
                painter: _EdgePainter(
                  screenAngleDegrees: alert.screenAngleDegrees,
                  strength: strength,
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _EdgePainter extends CustomPainter {
  _EdgePainter({required this.screenAngleDegrees, required this.strength});

  final double? screenAngleDegrees;
  final double strength;

  static const double _band = 10;
  static const double _bandLength = 280;
  static const double _glowRadius = 130;

  @override
  void paint(Canvas canvas, Size size) {
    final color = NavPalette.alert.withValues(alpha: 0.9 * strength);
    final angle = screenAngleDegrees;
    if (angle == null) {
      // 向き不明: 縁全体の帯。
      canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = _band * 2,
      );
      return;
    }
    // 自艇は横中央・上から navigationSelfBoatScreenRatio(追跡中の定位置)。
    final self = Offset(
      size.width / 2,
      size.height * navigationSelfBoatScreenRatio,
    );
    final p = edgeAnchorFor(angle, size, self);
    // 光(縁から約130pxで消える。艇の印とはなるべく重ねない)。
    canvas.drawCircle(
      p,
      _glowRadius,
      Paint()
        ..shader = RadialGradient(colors: [
          NavPalette.alert.withValues(alpha: 0.75 * strength),
          NavPalette.alert.withValues(alpha: 0.25 * strength),
          NavPalette.alert.withValues(alpha: 0),
        ], stops: const [
          0,
          0.45,
          1
        ]).createShader(Rect.fromCircle(center: p, radius: _glowRadius)),
    );
    // 帯(当たった辺に沿って、中心の前後 140px)。
    final vertical = p.dx <= 0.5 || p.dx >= size.width - 0.5;
    final Rect rect;
    if (vertical) {
      // 帯は辺の長さを超えない。分割画面などで辺が280より短いと、clampの
      // 上限が負になって例外になるため。
      final length = math.min(_bandLength, size.height);
      final top = (p.dy - length / 2).clamp(0.0, size.height - length);
      rect = Rect.fromLTWH(
        p.dx <= 0.5 ? 0 : size.width - _band,
        top,
        _band,
        length,
      );
    } else {
      final length = math.min(_bandLength, size.width);
      final left = (p.dx - length / 2).clamp(0.0, size.width - length);
      rect = Rect.fromLTWH(
        left,
        p.dy <= 0.5 ? 0 : size.height - _band,
        length,
        _band,
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(5)),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _EdgePainter old) =>
      old.strength != strength || old.screenAngleDegrees != screenAngleDegrees;
}
