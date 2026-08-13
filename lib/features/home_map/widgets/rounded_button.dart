import 'package:flutter/material.dart';

import '../../../utils/tactile_feedback.dart';

/// 画面下部の主要アクションボタン(航行スタート/終了など)。
/// 揺れる艇上でも確実に押せるよう大きめにし、
/// アイコン併記で一目で機能が分かるようにする。
///
/// 濡れた手・手袋では押せた手応えが無く、屋外では効果音も聞こえない。
/// タップ時に触覚を返し、押せたかどうかを画面を凝視せずに確かめられるようにする。
class RoundedButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color? color;

  /// 文字とアイコンの色。既定は白(濃い面色の上に置く前提)。
  ///
  /// 淡い面色を [color] に渡すときは必ず一緒に指定する。地図の上に置く
  /// ボタンなので、面と文字のどちらかが背景と同化すると読めなくなる。
  final Color? foregroundColor;

  /// 面色が淡いときの輪郭。地図の明るい部分の上で面の境界を保つ。
  final Color? borderColor;

  final bool compact;
  final VoidCallback onPressed;

  const RoundedButton({
    super.key,
    required this.label,
    this.icon,
    this.color,
    this.foregroundColor,
    this.borderColor,
    this.compact = false,
    required this.onPressed,
  });

  /// 半透明の面色を指定されたとき、下の地図と文字が混ざらないようにする影。
  /// 不透明な面でも見た目を損なわないので、常に付ける。
  static const List<Shadow> _labelHalo = [
    Shadow(color: Color(0xB3000000), blurRadius: 4),
  ];

  @override
  Widget build(BuildContext context) {
    final foreground = foregroundColor ?? Colors.white;
    final border = borderColor;
    final shape = border == null
        ? const StadiumBorder()
        : StadiumBorder(side: BorderSide(color: border, width: 1.5));
    return Material(
        color: color ?? Theme.of(context).primaryColor,
        elevation: 6.0,
        shape: shape,
        child: InkWell(
          onTap: () {
            TactileFeedback.selection();
            onPressed();
          },
          customBorder: shape,
          splashColor: foreground.withValues(alpha: 0.2),
          child: Padding(
            padding: EdgeInsets.symmetric(
              vertical: compact ? 12 : 20,
              horizontal: compact ? 24 : 36,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(
                    icon,
                    color: foreground,
                    size: compact ? 22 : 26,
                    shadows: border == null ? _labelHalo : null,
                  ),
                  SizedBox(width: compact ? 8 : 10),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: compact ? 16 : 20,
                    fontWeight: FontWeight.bold,
                    color: foreground,
                    // 淡い面のときに白いハローを敷くと文字が滲む。
                    shadows: border == null ? _labelHalo : null,
                  ),
                ),
              ],
            ),
          ),
        ));
  }
}
