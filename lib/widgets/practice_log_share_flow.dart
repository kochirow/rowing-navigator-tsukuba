import 'package:flutter/material.dart';

import '../models/practice_log_model.dart';
import '../services/practice_log_export_service.dart';
import '../services/practice_log_store_service.dart';
import 'share_delivery_prompt.dart';

/// 監視ログを共有する前の説明(R1-R10)。ひとことも送られることを書く。
const practiceLogShareNotice = '監視ログには全艇の航路と、監視者の「ひとこと」が'
    '含まれます（人の名前などを書いた場合も、そのまま届きます）。自動送信はされません。';

/// 1つの監視ログを共有する(艇名を伏せるか選ぶ→共有→送信済みの記録)。
///
/// 監視ログの一覧と、監視を終えたときの「今日の記録」シートの両方から呼ぶ。
/// 届いたときは true を返す。記録中のログには送信済みの印を付けない。
Future<bool> sharePracticeLog(
  BuildContext context, {
  required PracticeLog log,
  required Rect origin,
  PracticeLogStoreService? store,
  PracticeLogExportService? exporter,
}) async {
  final logStore = store ?? PracticeLogStoreService();
  final export = exporter ?? PracticeLogExportService();
  final anonymized = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
              // 選択肢はボタンの名前が言う。外へ出しても安全な側
              // (伏せる)を既定の塗りボタンにする。
              title: const Text('監視ログを共有'),
              content: const Text(practiceLogShareNotice),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialog, false),
                    child: const Text('艇名を含める')),
                FilledButton(
                    onPressed: () => Navigator.pop(dialog, true),
                    child: const Text('艇名を伏せる'))
              ]));
  if (anonymized == null || !context.mounted) return false;
  try {
    final data = await logStore.read(log.id);
    if (!context.mounted) return false;
    final result = await export.share(data.log, data.points, data.events,
        anonymized: anonymized, sharePositionOrigin: origin);
    // 届いたものは送信済みにする。まとめて送る対象から外れ、メニューの件数も減る。
    // 記録中のログは書込が続き、送信済みの印も記録側に上書きされるので印を付けない。
    if (!context.mounted || !data.log.isComplete) return false;
    if (await confirmShareDelivered(context, result)) {
      await logStore.markDiagnosticsShared(log.id, DateTime.now());
      return true;
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('監視ログを共有できませんでした。')));
    }
  }
  return false;
}
