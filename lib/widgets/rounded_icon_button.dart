import 'package:flutter/material.dart';

import 'map_control_button.dart';

/// マップ上に置く円形アイコンボタン(後方互換のための薄いラッパー)。
///
/// 見た目の実装は [MapControlButton] に一元化されている。既存の呼び出し側
/// (area_setting_screen 等)の API を保つため本クラスを残している。
class RoundedIconButton extends StatelessWidget {
  final IconData icon;
  final double? iconSize;
  final double angle;
  final Offset offset;
  final String? label;
  final Color? color;
  final VoidCallback? onPressed;

  const RoundedIconButton({
    super.key,
    required this.icon,
    this.iconSize = 30,
    this.angle = 0.0,
    this.offset = const Offset(0, 0),
    this.label,
    this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return MapControlButton(
      icon: icon,
      label: label,
      color: color,
      angle: angle,
      offset: offset,
      iconSize: iconSize ?? 30,
      onPressed: onPressed,
    );
  }
}
