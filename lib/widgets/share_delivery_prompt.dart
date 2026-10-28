import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

/// 共有の結果から「送れたか」を決める。
///
/// - 成功: 送れたとみなす。
/// - キャンセル: 送れていない。
/// - 結果が取れない(Android の一部の共有先など): 利用者に1回だけ聞く。
///   送れていないのに送信済みにすると、まとめて送る対象から黙って消えるため。
Future<bool> confirmShareDelivered(
    BuildContext context, ShareResult result) async {
  switch (result.status) {
    case ShareResultStatus.success:
      return true;
    case ShareResultStatus.dismissed:
      return false;
    case ShareResultStatus.unavailable:
      if (!context.mounted) return false;
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('送れましたか?'),
          content: const Text('この端末では、共有先へ届いたかを確かめられません。'
              '送れていれば「送信済みにする」を押してください。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(d).pop(false),
                child: const Text('送れていない')),
            FilledButton(
                onPressed: () => Navigator.of(d).pop(true),
                child: const Text('送信済みにする')),
          ],
        ),
      );
      return ok == true;
  }
}
