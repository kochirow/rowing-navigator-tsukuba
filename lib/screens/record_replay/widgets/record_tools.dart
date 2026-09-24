import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:share_plus/share_plus.dart';

import '../../../models/session_model.dart';
import '../../../services/gpx_export_service.dart';
import '../../../services/session_analyzer_service.dart';
import '../../../services/session_store_service.dart';
import '../../../theme/record_palette.dart';
import '../replay_format.dart';
import 'selection_card.dart';

/// 旧詳細画面から移した機能: 警告の振り返りと評価、共有（GPX/CSV/診断ZIP）、削除。
///
/// 表示を変えただけで、保存・共有・削除の中身は旧画面と同じ。
class RecordTools extends HookWidget {
  final Session session;
  final ValueChanged<Session> onSessionChanged;
  final GpxExportService exporter;
  final SessionStoreService store;
  final ValueChanged<double> onSeekTo;

  const RecordTools({
    super.key,
    required this.session,
    required this.onSessionChanged,
    required this.exporter,
    required this.store,
    required this.onSeekTo,
  });

  @override
  Widget build(BuildContext context) {
    final p = RecordPalette.of(context);
    final exporting = useState<String?>(null);
    final analyzer = useMemoized(SessionAnalyzerService.new);
    final episodes = useMemoized(
        () => analyzer.detectAlertEpisodes(session.alertEvents),
        [session.alertEvents]);

    Rect shareOrigin(BuildContext anchor) {
      final box = anchor.findRenderObject();
      if (box is RenderBox && box.hasSize && box.size.longestSide > 0) {
        final origin = box.localToGlobal(Offset.zero) & box.size;
        if (!origin.isEmpty) return origin;
      }
      final size = MediaQuery.sizeOf(context);
      return Rect.fromCenter(
          center: Offset(size.width / 2, size.height / 2), width: 1, height: 1);
    }

    String resultMessage(ShareResult r) => switch (r.status) {
          ShareResultStatus.success => '共有先へ航行記録を渡しました。',
          ShareResultStatus.dismissed => '共有をキャンセルしました。',
          ShareResultStatus.unavailable => '共有シートを開きました。完了結果はこの端末から取得できません。',
        };

    Future<void> runExport(String kind, Rect origin,
        Future<ShareResult> Function(Rect) action) async {
      if (exporting.value != null) return;
      exporting.value = kind;
      try {
        final r = await action(origin);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(resultMessage(r))));
      } catch (error) {
        if (!context.mounted) return;
        final message = error is SessionExportException
            ? error.message
            : '共有ファイルを作成できませんでした。';
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(message),
            action: SnackBarAction(
              label: '再試行',
              onPressed: () => unawaited(runExport(kind, origin, action)),
            ),
          ));
      } finally {
        if (context.mounted) exporting.value = null;
      }
    }

    Future<void> shareDiagnostics(BuildContext anchor) async {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('診断データを共有'),
          content: const Text(
            '診断ZIPには正確な航路、警告の発生状況、端末のOS情報、'
            '危険区域の設定が含まれます。自動送信はされません。'
            '内容を理解したうえで、共有先を自分で選んでください。',
          ),
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
      if (ok != true || !context.mounted) return;
      await runExport(
          'diagnostics',
          shareOrigin(anchor),
          (rect) => exporter.shareDiagnosticPackage(session,
              sharePositionOrigin: rect));
    }

    Future<void> saveRating(AlertEpisode e, AlertEpisodeRating? rating) async {
      final ratings = Map<String, String>.from(session.alertEpisodeRatings);
      if (rating == null) {
        ratings.remove(e.id);
      } else {
        ratings[e.id] = rating.name;
      }
      final previous = session;
      final updated = previous.copyWith(alertEpisodeRatings: ratings);
      onSessionChanged(updated);
      try {
        await store.saveSession(updated);
      } catch (_) {
        onSessionChanged(previous);
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('警告の評価を保存できませんでした。')));
        }
      }
    }

    Future<void> delete() async {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('記録の削除'),
          content: const Text('この記録を削除しますか?この操作は取り消せません。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(d).pop(false),
                child: const Text('キャンセル')),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFC62828)),
              onPressed: () => Navigator.of(d).pop(true),
              child: const Text('削除する'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      await store.deleteSession(session.id);
      if (context.mounted) Navigator.pop(context);
    }

    final eyebrow = TextStyle(
        fontSize: 12,
        letterSpacing: 1,
        fontWeight: FontWeight.w800,
        color: p.textSub);
    final busy = exporting.value != null;
    Widget progress() => const SizedBox.square(
        dimension: 18, child: CircularProgressIndicator(strokeWidth: 2));

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (episodes.isNotEmpty)
        RecordCard(
          palette: p,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('警告エピソード', style: eyebrow),
            const SizedBox(height: 6),
            Text('航跡の時刻と関連付けています。現地で感じた内容を選ぶと端末内の記録へ保存されます。',
                style: TextStyle(fontSize: 12, color: p.textSub)),
            for (final e in episodes)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      InkWell(
                        onTap: () => onSeekTo(e.startedAt
                                .difference(session.startedAt)
                                .inMilliseconds /
                            1000),
                        child: Text(
                          '${alertCategoryLabel(e.category)}  ${fmtClock(e.startedAt)}'
                          '（${e.durationSec.round()}秒）  地図で見る ›',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, color: p.text),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        [
                          '最大危険度: ${e.maxRiskLevel}',
                          if (e.minimumDistanceMeters != null)
                            '最短距離: ${e.minimumDistanceMeters!.toStringAsFixed(1)}m',
                          if (e.hadCurrentOverlap) '領域重なりあり',
                        ].join('  '),
                        style: TextStyle(fontSize: 12, color: p.textSub),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<AlertEpisodeRating>(
                        initialValue: AlertEpisodeRating.fromName(
                            session.alertEpisodeRatings[e.id]),
                        decoration: const InputDecoration(
                          labelText: 'この警告を評価',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: [
                          for (final v in AlertEpisodeRating.values)
                            DropdownMenuItem(
                                value: v, child: Text(v.displayLabel)),
                        ],
                        onChanged: (v) => saveRating(e, v),
                      ),
                    ]),
              ),
          ]),
        ),
      RecordCard(
        palette: p,
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('共有・削除', style: eyebrow),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: Builder(builder: (b) {
                return FilledButton.icon(
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48)),
                  icon: exporting.value == 'gpx'
                      ? progress()
                      : const Icon(Icons.share),
                  label:
                      Text(exporting.value == 'gpx' ? '作成中…' : 'GPX(Strava用)'),
                  onPressed: busy
                      ? null
                      : () => unawaited(runExport(
                          'gpx',
                          shareOrigin(b),
                          (rect) => exporter.shareAsGpx(session,
                              sharePositionOrigin: rect))),
                );
              }),
            ),
            const SizedBox(width: 8),
            Builder(builder: (b) {
              return OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                icon: exporting.value == 'csv'
                    ? progress()
                    : const Icon(Icons.table_chart_outlined),
                label: Text(exporting.value == 'csv' ? '作成中…' : 'CSV'),
                onPressed: busy
                    ? null
                    : () => unawaited(runExport(
                        'csv',
                        shareOrigin(b),
                        (rect) => exporter.shareAsCsv(session,
                            sharePositionOrigin: rect))),
              );
            }),
          ]),
          const SizedBox(height: 8),
          Builder(builder: (b) {
            return OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48)),
              icon: exporting.value == 'diagnostics'
                  ? progress()
                  : const Icon(Icons.bug_report_outlined),
              label: Text(
                  exporting.value == 'diagnostics' ? '診断ZIPを作成中…' : '診断データを共有'),
              onPressed: busy ? null : () => unawaited(shareDiagnostics(b)),
            );
          }),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFE57373),
              side: const BorderSide(color: Color(0xFFE57373)),
              minimumSize: const Size.fromHeight(48),
            ),
            icon: const Icon(Icons.delete_outline),
            label: const Text('この記録を削除'),
            onPressed: busy ? null : delete,
          ),
        ]),
      ),
    ]);
  }
}

String alertCategoryLabel(String category) => switch (category) {
      'shore' => '岸',
      'bridge' => '橋',
      'bridgePier' => '橋脚',
      'island' => '中州',
      'driftwood' => '流木',
      'pile' => '杭',
      'curve' => 'カーブ',
      'reverse' => '逆走注意',
      'other_boat' => '他艇',
      'other_boat_track_lost' => '他艇情報途絶',
      'gps_unavailable' => 'GPS利用不可',
      _ => category,
    };
