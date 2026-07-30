import 'dart:math';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../utils/tactile_feedback.dart';

/// マップ上に置く操作ボタンの共通部品(統一された見た目言語)。
///
/// - 濡れた手・手袋でも押せるよう十分なタップターゲット(直径約56dp)。
/// - [label] を指定すると直射日光下でも機能が分かるよう下に小ラベルを表示。
/// - [active] を true にするとトグルON状態(プライマリ面)へ反転。
///   追跡ON・艇一覧表示中・地図種別などの「選択中」を明示する。
/// - [color] を渡すと面色を上書き(例: 追加終了の danger)。
/// - [onPressed] が null のときは無効表示。
class MapControlButton extends StatelessWidget {
  final IconData icon;
  final String? label;
  final VoidCallback? onPressed;
  final bool active;
  final Color? color;
  final double angle; // 度
  final double iconSize;
  final Offset offset;

  const MapControlButton({
    super.key,
    required this.icon,
    this.label,
    this.onPressed,
    this.active = false,
    this.color,
    this.angle = 0.0,
    this.iconSize = 28,
    this.offset = Offset.zero,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    final disabled = onPressed == null;

    final Color surface;
    final Color foreground;
    if (color != null) {
      surface = color!;
      foreground = colors.onDark;
    } else if (active) {
      surface = colors.primary;
      foreground = colors.onPrimary;
    } else {
      surface = colors.mapControlSurface;
      foreground = colors.primary;
    }

    final button = Semantics(
      button: true,
      selected: active,
      enabled: !disabled,
      label: label,
      child: Opacity(
        opacity: disabled ? 0.5 : 1.0,
        child: Material(
          color: surface,
          elevation: dimens.elevationMd,
          shape: const CircleBorder(),
          child: InkWell(
            // 無効時は onTap を null のままにする。無効なボタンが押せるように
            // 見えると、押しても何も起きない理由を探すことになる。
            onTap: disabled
                ? null
                : () {
                    TactileFeedback.selection();
                    onPressed!();
                  },
            customBorder: const CircleBorder(),
            splashColor: colors.primary.withValues(alpha: 0.2),
            child: SizedBox.square(
              dimension: dimens.mapControlSize,
              child: Center(
                child: Transform.rotate(
                  angle: angle * (pi / 180),
                  child: Transform.translate(
                    offset: offset,
                    child: Icon(icon, color: foreground, size: iconSize),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    if (label == null) return button;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        button,
        SizedBox(height: dimens.space1),
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: dimens.space2,
            vertical: dimens.space1 / 2,
          ),
          decoration: BoxDecoration(
            color: colors.labelScrim,
            borderRadius: dimens.borderSm,
          ),
          child: Text(
            label!,
            style: TextStyle(
              color: colors.onDark,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}
