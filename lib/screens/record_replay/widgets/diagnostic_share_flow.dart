import 'package:flutter/material.dart';

import '../../../models/session_model.dart';
import '../../../services/gpx_export_service.dart';
import '../../../services/session_store_service.dart';
import '../../../widgets/share_delivery_prompt.dart';
import '../../../widgets/share_origin.dart';

/// 診断ZIPを作るときに利用者へ出す説明。まとめて送るときも同じ文を使う。
const diagnosticShareNotice = '診断ZIPには正確な航路、警告の発生状況、端末のOS情報、'
    '危険区域の設定が含まれます。自動送信はされません。'
    '内容を理解したうえで、共有先を自分で選んでください。';

/// 1つの記録の診断ログを送る(説明→共有→送信済みの記録)。
///
/// 記録画面の見出しの「ログを送る」と、下の共有カードの両方から呼ぶ。
/// 送れたときは送信時刻を付けて保存し、更新後の記録を返す。送れなかったときは null。
Future<Session?> shareSessionDiagnostics(
  BuildContext context, {
  required Session session,
  required GpxExportService exporter,
  required SessionStoreService store,
  required Rect origin,
  ValueChanged<bool>? onBusyChanged,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('診断ログを送る'),
      content: const Text(diagnosticShareNotice),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(d).pop(false),
            child: const Text('キャンセル')),
        FilledButton(
            onPressed: () => Navigator.of(d).pop(true),
            child: const Text('共有先を選ぶ')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return null;

  // 作成中の表示は、説明に「共有先を選ぶ」と答えてから出す。
  onBusyChanged?.call(true);
  final messenger = ScaffoldMessenger.of(context);
  try {
    final result = await exporter.shareDiagnosticPackage(session,
        sharePositionOrigin: origin);
    if (!context.mounted) return null;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
          SnackBar(content: Text(shareResultMessage(result, what: '診断ログ'))));
    final delivered = await confirmShareDelivered(context, result);
    if (!delivered) return null;
    final updated = session.copyWith(diagnosticsSharedAt: () => DateTime.now());
    try {
      await store.saveSession(updated);
    } catch (_) {
      messenger
          .showSnackBar(const SnackBar(content: Text('送信済みの印を保存できませんでした。')));
      return null;
    }
    return updated;
  } catch (error) {
    final message =
        error is SessionExportException ? error.message : '共有ファイルを作成できませんでした。';
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
    return null;
  } finally {
    onBusyChanged?.call(false);
  }
}
