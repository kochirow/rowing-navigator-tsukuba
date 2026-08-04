import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';

/// マップの操作メニュー1項目。
class MapMenuAction {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final Color? iconColor;

  /// false のとき、項目を消さずに無効表示で残す。
  ///
  /// 航行中に項目そのものが消えると、5項目が1項目に減って位置も変わるため、
  /// 「壊れた」「どこへ行った」と感じる。残したうえで理由を添えるほうが、
  /// 次に何をすれば使えるのかが分かる。
  final bool enabled;

  /// 無効な理由。`enabled` が false のときだけ [subtitle] の代わりに出す。
  final String? disabledReason;

  const MapMenuAction({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.iconColor,
    this.enabled = true,
    this.disabledReason,
  });
}

/// マップ右側に集約した副次操作を開くボトムシート。
///
/// 常時マップ上に並べると小型端末でオーバーフローするため、頻用しない操作
/// (チーム/記録/障害物の追加/安全設定/詳細など)はここへ集約する。項目が増えても
/// スクロールで破綻しない。
class MapMenuSheet extends StatelessWidget {
  final List<MapMenuAction> actions;
  final double heightFactor;

  const MapMenuSheet({
    super.key,
    required this.actions,
    this.heightFactor = 0.8,
  }) : assert(heightFactor > 0 && heightFactor <= 1);

  static String? _subtitleOf(MapMenuAction action) => action.enabled
      ? action.subtitle
      : (action.disabledReason ?? action.subtitle);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    // ListTile はインク/背景を最近傍の Material に描くため、色付き
    // DecoratedBox ではなく Material をルートにする(色が隠れる警告を防ぐ)。
    //
    // 高さは中身に合わせ、[heightFactor] は上限としてだけ使う。固定高だと
    // 航行中の5項目でシートの下半分が空白になり、項目が途中で切れている
    // ように見える。項目が増えたときだけスクロールする。
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * heightFactor,
      ),
      child: Material(
        color: colors.card,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(dimens.radiusLg),
          ),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // つまみ(シートであることを示す)
                Container(
                  width: 36,
                  height: 4,
                  margin: EdgeInsets.only(
                    top: dimens.space3,
                    bottom: dimens.space2,
                  ),
                  decoration: BoxDecoration(
                    color: colors.textDisabled,
                    borderRadius: dimens.borderSm,
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    dimens.space5,
                    dimens.space1,
                    dimens.space5,
                    dimens.space1,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'メニュー',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ),
                for (final action in actions)
                  ListTile(
                    enabled: action.enabled,
                    minVerticalPadding: dimens.space3,
                    leading: Icon(
                      action.icon,
                      color: action.enabled
                          ? (action.iconColor ?? colors.primary)
                          : colors.textDisabled,
                      size: 26,
                    ),
                    title: Text(
                      action.title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: action.enabled ? null : colors.textDisabled,
                      ),
                    ),
                    subtitle: _subtitleOf(action) == null
                        ? null
                        : Text(_subtitleOf(action)!),
                    trailing: Icon(
                      action.enabled ? Icons.chevron_right : Icons.lock_outline,
                      color: action.enabled ? null : colors.textDisabled,
                    ),
                    onTap: action.enabled
                        ? () {
                            Navigator.of(context).pop();
                            action.onTap();
                          }
                        : null,
                  ),
                SizedBox(height: dimens.space2),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
