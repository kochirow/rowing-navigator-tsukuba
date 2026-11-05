import 'package:flutter/material.dart';

import '../models/practice_log_model.dart';
import '../services/diagnostic_bundle_service.dart';
import '../services/practice_log_export_service.dart';
import '../services/practice_log_store_service.dart';
import '../theme/app_theme.dart';
import '../widgets/log_sent_status.dart';
import '../widgets/practice_log_share_flow.dart';
import 'record_list_screen.dart' show formatDateTime;

class PracticeLogListScreen extends StatefulWidget {
  /// テストで差し替える。null なら端末内の保存場所を使う。
  final PracticeLogStoreService? store;
  const PracticeLogListScreen({super.key, this.store});
  @override
  State<PracticeLogListScreen> createState() => _PracticeLogListScreenState();
}

class _PracticeLogListScreenState extends State<PracticeLogListScreen> {
  late final PracticeLogStoreService _store =
      widget.store ?? PracticeLogStoreService();
  final _export = PracticeLogExportService();
  late Future<List<PracticeLog>> _logs;

  /// 長押しで入る選択モードで選んだログのid。空なら選択モードではない。
  /// 選べるのは、まとめて送る条件を満たすログだけ(満たさないものは
  /// 未送信の件数に数えないので、切り替える意味がない)。
  Set<String> _selected = const {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  // 本体を波かっこで書く。`=>` だと代入した Future を返し、
  // setState(_reload) が「Futureを返した」として例外になる。
  void _reload() {
    _logs = _store.list();
  }

  Future<void> _share(PracticeLog log) async {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? const Rect.fromLTWH(0, 0, 1, 1)
        : box.localToGlobal(Offset.zero) & box.size;
    final shared = await sharePracticeLog(context,
        log: log, origin: origin, store: _store, exporter: _export);
    if (shared && mounted) setState(_reload);
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

  void _toggleSelected(PracticeLog log) => setState(() {
        final next = {..._selected};
        if (!next.remove(log.id)) next.add(log.id);
        _selected = next;
      });

  /// 送信済みの印を付ける・外す。もう送信済みのものは送った時刻を残す。
  /// 終わったら「元に戻す」付きで結果を伝える。
  Future<void> _setShared(List<PracticeLog> targets, bool toShared) async {
    final now = DateTime.now();
    final changed = <PracticeLog>[];
    var failed = 0;
    for (final l in targets) {
      if (l.isDiagnosticsShared == toShared) continue;
      try {
        await _store.markDiagnosticsShared(l.id, toShared ? now : null);
        changed.add(l);
      } catch (_) {
        // 1件の失敗で残りを止めない。保存できなかった分は元のまま残る。
        failed++;
      }
    }
    if (!mounted) return;
    setState(_reload);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(logSentToggleMessage(
            changed: changed.length, failed: failed, toShared: toShared)),
        action: changed.isEmpty
            ? null
            : SnackBarAction(
                label: '元に戻す',
                onPressed: () async {
                  for (final l in changed) {
                    try {
                      await _store.markDiagnosticsShared(
                          l.id, l.diagnosticsSharedAt);
                    } catch (_) {}
                  }
                  if (mounted) setState(_reload);
                },
              ),
      ));
  }

  Future<void> _applyToSelected(List<PracticeLog> logs, bool toShared) async {
    final targets = [
      for (final l in logs)
        if (_selected.contains(l.id) && isBulkPracticeLogCandidate(l)) l
    ];
    setState(() => _selected = const {});
    await _setShared(targets, toShared);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<PracticeLog>>(
      future: _logs,
      builder: (context, snapshot) {
        final logs = snapshot.data ?? const <PracticeLog>[];
        final candidates = logs.where(isBulkPracticeLogCandidate).toList();
        final selecting = _selected.isNotEmpty;
        final allSelected =
            candidates.isNotEmpty && _selected.length == candidates.length;
        return PopScope(
          // 選択モード中の「戻る」は、画面を閉じずに選択をやめる。
          canPop: !selecting,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) setState(() => _selected = const {});
          },
          child: Scaffold(
            appBar: selecting
                ? AppBar(
                    leading: IconButton(
                        tooltip: '選択をやめる',
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() => _selected = const {})),
                    title: Text('${_selected.length}件を選択'),
                    actions: [
                      TextButton(
                          key: const Key('practice-log-select-all'),
                          // 見出しの帯と同じ色の文字になり見えなくなるので、帯の上の文字色にする。
                          style: TextButton.styleFrom(
                              foregroundColor: context.colors.onPrimary),
                          onPressed: () => setState(() => _selected =
                              allSelected
                                  ? const {}
                                  : {for (final l in candidates) l.id}),
                          child: Text(allSelected ? '選択を解除' : 'すべて選択')),
                    ],
                  )
                : AppBar(title: const Text('監視ログ')),
            bottomNavigationBar: !selecting
                ? null
                : SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            key: const Key('practice-log-selected-unsent'),
                            style: OutlinedButton.styleFrom(
                                minimumSize: const Size.fromHeight(48)),
                            icon: const Icon(Icons.outgoing_mail),
                            label: const Text('未送信に戻す'),
                            onPressed: () => _applyToSelected(logs, false),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton.icon(
                            key: const Key('practice-log-selected-sent'),
                            style: FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(48)),
                            icon: const Icon(Icons.mark_email_read_outlined),
                            label: const Text('送信済みにする'),
                            onPressed: () => _applyToSelected(logs, true),
                          ),
                        ),
                      ]),
                    ),
                  ),
            body: _buildList(snapshot, logs, selecting),
          ),
        );
      });

  Widget _buildList(AsyncSnapshot<List<PracticeLog>> snapshot,
      List<PracticeLog> logs, bool selecting) {
    if (snapshot.connectionState != ConnectionState.done) {
      return const Center(child: CircularProgressIndicator());
    }
    if (logs.isEmpty) {
      return const Center(
          child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('監視中の記録がここに並びます', textAlign: TextAlign.center)));
    }
    return ListView.builder(
        itemCount: logs.length,
        itemBuilder: (context, index) {
          final log = logs[index];
          final candidate = isBulkPracticeLogCandidate(log);
          final minutes = log.endedAt?.difference(log.startedAt).inMinutes;
          final detail = [
            if (!log.isComplete) '未完了' else if (minutes != null) '$minutes分',
            // 札を出さないログは、これまでどおり文字で送信済みを示す。
            if (!candidate && log.isDiagnosticsShared) '送信済み',
          ].join(' ・ ');
          final selected = _selected.contains(log.id);
          // 行を押すと共有(主な用途)。削除だけを右端に置く。
          // 選択モード中は、押すと選ぶ・外す。
          final tile = ListTile(
              key: Key('practice-log-row-${log.id}'),
              leading: selecting && candidate
                  ? Icon(
                      selected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      key: Key('practice-log-select-${log.id}'),
                      color: selected
                          ? context.colors.primary
                          : context.colors.textSecondary)
                  : Icon(log.isComplete
                      ? Icons.ios_share
                      : Icons.warning_amber_rounded),
              title: Text(formatDateTime(log.startedAt.toLocal())),
              subtitle: candidate
                  ? Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      children: [
                        if (detail.isNotEmpty) Text(detail),
                        LogSentStatusChip(
                          key: Key('practice-log-sent-chip-${log.id}'),
                          sharedAt: log.diagnosticsSharedAt,
                          onToggle: selecting
                              ? null
                              : () =>
                                  _setShared([log], !log.isDiagnosticsShared),
                        ),
                      ],
                    )
                  : Text(detail),
              selected: selecting && selected,
              onTap: selecting
                  ? (candidate ? () => _toggleSelected(log) : null)
                  : () => _share(log),
              onLongPress:
                  !selecting && candidate ? () => _toggleSelected(log) : null,
              trailing: selecting
                  ? null
                  : IconButton(
                      tooltip: 'この端末から削除',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _delete(log)));
          if (selecting && !candidate) {
            return Opacity(opacity: 0.45, child: tile);
          }
          if (selecting || !candidate) return tile;
          // 右へスワイプしても切り替えられる(札を押すのと同じ。補助の操作)。
          return Dismissible(
            key: ValueKey('practice-log-swipe-${log.id}'),
            direction: DismissDirection.startToEnd,
            dismissThresholds: const {DismissDirection.startToEnd: 0.3},
            background:
                LogSentSwipeBackground(currentlySent: log.isDiagnosticsShared),
            confirmDismiss: (_) async {
              await _setShared([log], !log.isDiagnosticsShared);
              return false;
            },
            child: tile,
          );
        });
  }
}
