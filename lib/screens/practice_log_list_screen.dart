import 'package:flutter/material.dart';

import '../models/practice_log_model.dart';
import '../services/practice_log_export_service.dart';
import '../services/practice_log_store_service.dart';

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
                title: const Text('練習一括ログを共有'),
                content: const Text('チーム内の検証用には艇名を含めます。外部へ提出する場合は艇名を伏せてください。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialog, true),
                      child: const Text('艇名を伏せる')),
                  FilledButton(
                      onPressed: () => Navigator.pop(dialog, false),
                      child: const Text('艇名を含める'))
                ]));
    if (anonymized == null || !mounted) return;
    try {
      final data = await _store.read(log.id);
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      final origin = box == null
          ? const Rect.fromLTWH(0, 0, 1, 1)
          : box.localToGlobal(Offset.zero) & box.size;
      await _export.share(data.log, data.points, data.events,
          anonymized: anonymized, sharePositionOrigin: origin);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('練習一括ログを共有できませんでした。')));
      }
    }
  }

  Future<void> _delete(PracticeLog log) async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
                title: const Text('練習一括ログを削除'),
                content:
                    const Text('この端末の一括ログを削除します。共有済みのファイルや他の端末の記録は削除されません。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialog, false),
                      child: const Text('キャンセル')),
                  FilledButton(
                      onPressed: () => Navigator.pop(dialog, true),
                      style:
                          FilledButton.styleFrom(backgroundColor: Colors.red),
                      child: const Text('削除'))
                ]));
    if (ok != true) return;
    await _store.delete(log.id);
    if (mounted) setState(_reload);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('練習一括ログ')),
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
                      child: Text(
                          '監視スタート中に記録した練習一括ログがここに表示されます。\n位置履歴はこの端末だけに保存され、自動送信されません。',
                          textAlign: TextAlign.center)));
            }
            return ListView.builder(
                itemCount: logs.length,
                itemBuilder: (context, index) {
                  final log = logs[index];
                  return ListTile(
                      leading: Icon(log.isComplete
                          ? Icons.inventory_2_outlined
                          : Icons.warning_amber_rounded),
                      title: Text('${log.startedAt.toLocal()}'),
                      subtitle: Text(
                          '${log.pointCount} 点・${log.eventCount} 件${log.isComplete ? '' : '・未完了（次回起動時に確認）'}'),
                      trailing: PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'share') _share(log);
                            if (value == 'delete') _delete(log);
                          },
                          itemBuilder: (_) => const [
                                PopupMenuItem(
                                    value: 'share', child: Text('ZIPを共有')),
                                PopupMenuItem(
                                    value: 'delete', child: Text('この端末から削除'))
                              ]));
                });
          }));
}
