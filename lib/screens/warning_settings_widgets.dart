import 'package:flutter/material.dart';

import '../config/risk_evaluator_config.dart';
import '../theme/app_theme.dart';

/// 警告の設定画面の部品(表示と入力だけ。値の範囲・保存は画面側が持つ)。

/// 艇種ごとの止まるまでの時間 [秒](`boat_config.dart` の停止距離の式の根拠)。
/// 確度の低い当たり予測の鳴り始めを、これより短くできない理由を図で見せる。
const _stopSeconds = {'2x': 6.60, '4x': 6.68, '1x': 6.95, '8+': 8.15};

/// 「残り秒数」の1本の軸に、鳴る帯・確実なときだけ鳴る帯・音なしの帯と、
/// 艇種ごとの止まるまでの時間を並べた図。長い説明文とスライダーでは
/// 読み取れなかった関係を、図1枚で見せる。
///
/// 警告音は1種類(2026-10-23)。帯の違いは鳴り方ではなく、
/// 「確度が低い当たり予測でも鳴るか」だけである。
class LeadTimeAxis extends StatelessWidget {
  const LeadTimeAxis({
    super.key,
    required this.primarySeconds,
    required this.advanceSeconds,
  });

  final double primarySeconds;
  final double advanceSeconds;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      label: '警告音は${advanceSeconds.toStringAsFixed(0)}秒前から、'
          '不確かなときは${primarySeconds.toStringAsFixed(1)}秒前から',
      child: SizedBox(
        height: 120,
        child: CustomPaint(
          size: Size.infinite,
          painter: _AxisPainter(
            primary: primarySeconds,
            advance: advanceSeconds,
            danger: colors.danger,
            warning: colors.warning,
            track: colors.textDisabled.withValues(alpha: 0.25),
            text: colors.textPrimary,
            sub: colors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _AxisPainter extends CustomPainter {
  _AxisPainter({
    required this.primary,
    required this.advance,
    required this.danger,
    required this.warning,
    required this.track,
    required this.text,
    required this.sub,
  });

  final double primary, advance;
  final Color danger, warning, track, text, sub;

  @override
  void paint(Canvas canvas, Size size) {
    const maxT = maxWarningTimeSeconds;
    const left = 4.0;
    final right = size.width - 4;
    double x(double s) => left + (right - left) * s / maxT;
    const barTop = 20.0, barH = 28.0;
    final r = RRect.fromLTRBR(
        left, barTop, right, barTop + barH, const Radius.circular(8));
    canvas.drawRRect(r, Paint()..color = track);
    canvas.save();
    canvas.clipRRect(r);
    canvas.drawRect(Rect.fromLTRB(left, barTop, x(primary), barTop + barH),
        Paint()..color = danger);
    canvas.drawRect(
        Rect.fromLTRB(x(primary), barTop, x(advance), barTop + barH),
        Paint()..color = warning);
    canvas.restore();
    void label(String s, Offset at, Color c,
        {double size = 12,
        bool bold = true,
        TextAlign align = TextAlign.left}) {
      final tp = TextPainter(
        text: TextSpan(
            text: s,
            style: TextStyle(
                color: c,
                fontSize: size,
                fontWeight: bold ? FontWeight.w800 : FontWeight.w600)),
        textDirection: TextDirection.ltr,
      )..layout();
      final dx = switch (align) {
        TextAlign.center => at.dx - tp.width / 2,
        TextAlign.right => at.dx - tp.width,
        _ => at.dx,
      };
      tp.paint(canvas, Offset(dx, at.dy));
      tp.dispose();
    }

    label('衝突', const Offset(left, 0), sub);
    label('${maxT.toStringAsFixed(0)}秒先', Offset(right, 0), sub,
        align: TextAlign.right);
    if (x(primary) - left > 52) {
      label('鳴る', Offset((left + x(primary)) / 2, barTop + 7), Colors.white,
          align: TextAlign.center);
    }
    // 既定(10秒・13秒)では帯が約47px(幅402pt)しかないので、2文字に収める。
    if (x(advance) - x(primary) > 30) {
      label(
          '確実', Offset((x(primary) + x(advance)) / 2, barTop + 7), Colors.black,
          align: TextAlign.center);
    }
    label('音なし(予測の外)', Offset((x(advance) + right) / 2, barTop + 7), sub,
        bold: false, align: TextAlign.center);
    // 秒の目盛り
    for (final s in [0, 5, 10, 15, 20, 25]) {
      label('$s', Offset(x(s.toDouble()), barTop + barH + 4), sub,
          size: 11, bold: false, align: TextAlign.center);
    }
    // 止まるまでの時間(▲)
    for (final e in _stopSeconds.entries) {
      final big = e.key == '8+';
      final px = x(e.value);
      final path = Path()
        ..moveTo(px, barTop + barH + 22)
        ..lineTo(px + (big ? 5 : 4), barTop + barH + 31)
        ..lineTo(px - (big ? 5 : 4), barTop + barH + 31)
        ..close();
      canvas.drawPath(path, Paint()..color = big ? text : sub);
    }
    label('▲ 止まるまでの時間  1x・2x・4x 約7秒 / 8+ 8.15秒(最長)',
        Offset(left, barTop + barH + 36), sub,
        bold: false);
  }

  @override
  bool shouldRepaint(covariant _AxisPainter o) =>
      o.primary != primary || o.advance != advance || o.danger != danger;
}

/// 大きな −/+ で値を1刻みずつ変える。スライダーより狙った値に合わせやすい。
class ValueStepper extends StatelessWidget {
  const ValueStepper({
    super.key,
    required this.label,
    required this.value,
    required this.changed,
    this.caption,
    this.onDecrement,
    this.onIncrement,
    this.keyPrefix,
  });

  final String label;
  final String value;

  /// 既定から変えたか(「変更」の印を出す)。
  final bool changed;
  final String? caption;
  final VoidCallback? onDecrement;
  final VoidCallback? onIncrement;

  /// テストや自動操作で −/+ を見つけるための key の頭。
  final String? keyPrefix;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(label,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w800)),
                  ),
                  // 印は変えた項目にだけ付ける。全項目に「既定」が
                  // 並ぶと、変えた項目の「変更」が目立たない。
                  if (changed) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: colors.primary.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text('変更',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: colors.primary)),
                    ),
                  ],
                ]),
                if (caption != null)
                  Text(caption!,
                      style:
                          TextStyle(fontSize: 12, color: colors.textSecondary)),
              ],
            ),
          ),
          IconButton.outlined(
            key: keyPrefix == null ? null : ValueKey('$keyPrefix-minus'),
            onPressed: onDecrement,
            icon: const Icon(Icons.remove),
            tooltip: '減らす',
          ),
          // 値は必ず1行で出す。「10.0秒前」が84幅では「秒前」だけ次の行へ
          // 落ちていた(2026-10-23 シミュレーターで確認)。幅を広げたうえで、
          // 文字サイズを大きくした端末でも折り返さず縮めて収める。
          SizedBox(
            width: 100,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value,
                  key: keyPrefix == null ? null : ValueKey('$keyPrefix-value'),
                  maxLines: 1,
                  softWrap: false,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      fontFeatures: [FontFeature.tabularFigures()])),
            ),
          ),
          IconButton.outlined(
            key: keyPrefix == null ? null : ValueKey('$keyPrefix-plus'),
            onPressed: onIncrement,
            icon: const Icon(Icons.add),
            tooltip: '増やす',
          ),
        ],
      ),
    );
  }
}
