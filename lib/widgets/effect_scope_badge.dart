import 'package:flutter/material.dart';

/// 変更が「誰に・いつ」効くか(要件定義 11/03 R6 段1)。
///
/// 危険区域に関わる変更は効き方が3通りあり、画面からは見えなかった
/// (すぐチーム全員に反映/公開するとチーム全員に反映/自艇のこの航行だけ)。
/// 設定の見出しに札を付けて、押す前に分かるようにする。
enum EffectScope {
  /// 臨時の危険区域・流木。保存した瞬間にチーム全員に効く。
  teamImmediately,

  /// 警告の設定・位置調整。この端末で変えて「チームに公開」すると全員に効く。
  teamAfterPublish,

  /// 開発者用の表示・位置の取り方など。この端末だけ。
  thisDevice,

  /// 航行中の警告設定。自艇のこの航行だけ。
  thisNavigation;

  String get label => switch (this) {
        EffectScope.teamImmediately => 'すぐチーム全員に反映',
        EffectScope.teamAfterPublish => '公開するとチーム全員に反映',
        EffectScope.thisDevice => 'この端末だけ',
        EffectScope.thisNavigation => 'この航行だけ（自艇）',
      };

  IconData get icon => switch (this) {
        EffectScope.teamImmediately => Icons.groups,
        EffectScope.teamAfterPublish => Icons.publish_outlined,
        EffectScope.thisDevice => Icons.smartphone,
        EffectScope.thisNavigation => Icons.rowing,
      };
}

class EffectScopeBadge extends StatelessWidget {
  final EffectScope scope;
  const EffectScopeBadge(this.scope, {super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final team = scope == EffectScope.teamImmediately ||
        scope == EffectScope.teamAfterPublish;
    return Semantics(
      label: '反映される範囲：${scope.label}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color:
              team ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(scope.icon,
                size: 14,
                color: team ? scheme.onPrimaryContainer : scheme.onSurface),
            const SizedBox(width: 4),
            Text(
              scope.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: team ? scheme.onPrimaryContainer : scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
