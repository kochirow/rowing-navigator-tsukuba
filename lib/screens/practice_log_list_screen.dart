import 'package:flutter/material.dart';

import '../models/practice_log_model.dart';
import '../services/practice_log_export_service.dart';
import '../services/practice_log_store_service.dart';
import '../theme/app_theme.dart';
import '../widgets/share_delivery_prompt.dart';
import 'record_list_screen.dart' show formatDateTime;

class PracticeLogListScreen extends StatefulWidget {
  const PracticeLogListScreen({super.key});
  @override
  State<PracticeLogListScreen> createState() => _PracticeLogListScreenState();
}

class _PracticeLogListScreenState extends State<PracticeLogListScreen> {
  final _store = PracticeLogStoreService();
  final _export = PracticeLogExportService();
  late Future<List<PracticeLog>> _logs;
  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() => _logs = _store.list();
  Future<void> _share(PracticeLog log) async {
    final anonymized = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
                // 選択肢はボタンの名前が言う。外へ出しても安全な側
                // (伏せる)を既定の塗りボタンにする。
                title: const Text('監視ログを共有'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialog, false),
                      child: const Text('艇名を含める')),
                  FilledButton(
                      onPressed: () => Navigator.pop(dialog, true),
                      child: const Text('艇名を伏せる'))
                ]));
    if (anonymized == null || !mounted) return;
    try {
      final data = await _store.read(log.id);
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      final origin = box == null
          ? const Rect.fromLTWH(0, 0, 1, 1)
          : box.localToGlobal(Offset.zero) & box.size;
      final result = await _export.share(data.log, data.points, data.events,
          anonymized: anonymized, sharePositionOrigin: origin);
      // 届いたものは送信済みにする。まとめて送る対象から外れ、メニューの件数も減る。
      // 記録中のログは書込が続き、送信済みの印も記録側に上書きされるので印を付けない。
      if (!mounted || !data.log.isComplete) return;
      if (await confirmShareDelivered(context, result)) {
        await _store.markDiagnosticsShared(log.id, DateTime.now());
        if (mounted) setState(_reload);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('監視ログを共有できませんでした。')));
      }
    }
  }

  Future<void> _delete(PracticeLog log) async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
                title: const Text('監視ログを削除しますか?'),
                content: const Text('共有済みのファイルは消えません。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialog, false),
                      child: const Text('キャンセル')),
                  FilledButton(
                      onPressed: () => Navigator.pop(dialog, true),
                      style: FilledButton.styleFrom(
                          backgroundColor: context.colors.danger),
                      child: const Text('削除'))
                ]));
    if (ok != true) return;
    await _store.delete(log.id);
    if (mounted) setState(_reload);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('監視ログ')),
      body: FutureBuilder<List<PracticeLog>>(
          future: _logs,
          builder: (context, snapshot) {
            final logs = snapshot.data ?? const <PracticeLog>[];
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (logs.isEmpty) {
              return const Center(
                  child: Padding(
                      padding: EdgeInsets.all(24),
                      child:
                          Text('監視中の記録がここに並びます', textAlign: TextAlign.center)));
            }
            return ListView.builder(
                itemCount: logs.length,
                itemBuilder: (context, index) {
                  final log = logs[index];
                  final minutes =
                      log.endedAt?.difference(log.startedAt).inMinutes;
                  // 行を押すと共有(主な用途)。削除だけを右端に置く。
                  return ListTile(
                      leading: Icon(log.isComplete
                          ? Icons.ios_share
                          : Icons.warning_amber_rounded),
                      title: Text(formatDateTime(log.startedAt.toLocal())),
                      subtitle: Text([
                        if (!log.isComplete)
                          '未完了'
                        else if (minutes != null)
                          '$minutes分',
                        if (log.isDiagnosticsShared) '送信済み',
                      ].join(' ・ ')),
                      onTap: () => _share(log),
                      trailing: IconButton(
                          tooltip: 'この端末から削除',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _delete(log)));
                });
          }));
}
