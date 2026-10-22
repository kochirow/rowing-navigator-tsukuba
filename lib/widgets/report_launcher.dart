import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/store_config.dart';

/// 通報フォームを、対象を特定できる文面つきで開く。
///
/// 通報の受付は運営の Google フォームだけにしている(store_config.dart)。
/// フォームの項目IDに依存しないよう、対象の説明はクリップボードへ入れ、
/// 貼り付けてもらう。App Store 審査ガイドライン 1.2(ユーザー投稿の通報)の
/// 「対象から通報できる」導線として、危険区域などの画面から呼ぶ。
Future<void> openReportForm(
  BuildContext context, {
  required String subject,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await Clipboard.setData(ClipboardData(text: '通報対象: $subject'));
  } catch (_) {
    // コピーできなくてもフォームは開く。
  }
  final opened = await launchUrl(
    Uri.parse(supportReportFormUrl),
    mode: LaunchMode.externalApplication,
  );
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        opened
            ? '通報の対象をコピーしました。フォームの本文へ貼り付けてください。'
            : '通報フォームを開けませんでした。通信を確認してください。',
      ),
    ),
  );
}
