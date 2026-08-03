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
  final bool compact;
  final VoidCallback onPressed;

  const RoundedButton({
    super.key,
    required this.label,
    this.icon,
    this.color,
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
    return Material(
        color: color ?? Theme.of(context).primaryColor,
        elevation: 6.0,
        shape: const StadiumBorder(),
        child: InkWell(
          onTap: () {
            TactileFeedback.selection();
            onPressed();
          },
          customBorder: const StadiumBorder(),
          splashColor: Colors.white.withValues(alpha: 0.3),
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
                    color: Colors.white,
                    size: compact ? 22 : 26,
                    shadows: _labelHalo,
                  ),
                  SizedBox(width: compact ? 8 : 10),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: compact ? 16 : 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    shadows: _labelHalo,
                  ),
                ),
              ],
            ),
          ),
        ));
  }
}
