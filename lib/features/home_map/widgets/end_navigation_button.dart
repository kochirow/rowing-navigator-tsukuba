import 'package:flutter/material.dart';

import '../../../theme/nav_palette.dart';

/// 航行終了(左下の列の一番下、小さく灰色)。
///
/// 押すのは余裕のあるときなので、大きさより地図の邪魔をしないことを優先する
/// (2026-09-26 利用者)。誤タップで位置共有・警告が止まるのを防ぐため、
/// **必ず確認ダイアログを挟む**。
class EndNavigationButton extends StatelessWidget {
  const EndNavigationButton({super.key, required this.onStop});

  /// 確認後に呼ぶ。資源解放を最優先で行うもの(`UseNavigator.stopNavigation`)。
  final Future<void> Function() onStop;

  Future<void> _confirmAndStop(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('航行を終了しますか?'),
        content: const Text('位置共有と衝突警告が停止し、練習記録が保存されます。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFC62828),
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('終了する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      // 地図描画の状態に関係なく、資源解放を最優先で実行する。
      await onStop();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('航行終了処理でエラーが発生しました。資源解放は継続しました: $error'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '航行終了',
      excludeSemantics: true,
      child: Material(
        color: NavPalette.surface,
        shape: const StadiumBorder(side: BorderSide(color: Color(0xFF2A333D))),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => _confirmAndStop(context),
          child: const SizedBox(
            height: 40,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.stop_circle_outlined,
                      size: 18, color: NavPalette.label),
                  SizedBox(width: 6),
                  Text(
                    '終了',
                    style: TextStyle(
                      color: NavPalette.label,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
