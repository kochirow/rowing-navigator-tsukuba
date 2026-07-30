import 'package:flutter/material.dart';

/// Google Playのバックグラウンド位置情報要件に対応する明示説明。
///
/// OSの権限ダイアログより前に表示し、航行中に取得・共有する情報と
/// 利用目的を、利用者自身の操作で確認してもらう。
class BackgroundLocationDisclosureDialog extends StatelessWidget {
  const BackgroundLocationDisclosureDialog({super.key});

  static const title = 'バックグラウンド位置情報について';
  static const description =
      'Rowing Navigatorは、航行中の接近警告・艇間位置共有・練習記録のため、アプリを使用していないとき（画面消灯中や別アプリ表示中）も位置情報を取得します。\n\n'
      '現在地・進行方向・速度は、周囲の艇との接近警告と艇間の位置共有に使用し、Firebaseへ一時送信します。招待コードで参加した同一チームの艇と監視端末だけが確認できます。\n\n'
      '航行を終了するとリアルタイム位置情報はサーバーから削除します。広告への利用やデータの販売は行いません。';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(title),
      content: const SingleChildScrollView(child: Text(description)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('同意して続ける'),
        ),
      ],
    );
  }
}
