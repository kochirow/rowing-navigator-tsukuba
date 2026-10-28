import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:share_plus/share_plus.dart';

import '../../../config/log_export_config.dart';
import '../../../models/session_model.dart';
import '../../../models/static_obstacle_model.dart';
import '../../../services/gpx_export_service.dart';
import '../../../services/session_analyzer_service.dart';
import '../../../services/session_store_service.dart';
import '../../../theme/record_palette.dart';
import '../../../widgets/share_origin.dart';
import '../replay_format.dart';
import 'selection_card.dart';

/// 記録画面の下段: 共有(診断ログ・GPX・CSV)、警告の振り返り、削除。
///
/// 共有を先に置く。ログの回収が最優先で、以前は警告エピソードを全件
/// (1練習で数十〜数百件)並べた下にあり、届かなかった(2026-10-28)。
class RecordTools extends HookWidget {
  final Session session;
  final ValueChanged<Session> onSessionChanged;
  final GpxExportService exporter;
  final SessionStoreService store;
  final ValueChanged<double> onSeekTo;

  /// 診断ログを送る(見出しのボタンと同じ処理)。押したボタンの位置を渡す。
  final ValueChanged<Rect> onShareDiagnostics;
  final bool sharingDiagnostics;

  const RecordTools({
    super.key,
    required this.session,
    required this.onSessionChanged,
    required this.exporter,
    required this.store,
    required this.onSeekTo,
    required this.onShareDiagnostics,
    this.sharingDiagnostics = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = RecordPalette.of(context);
    final exporting = useState<String?>(null);

    Future<void> runExport(String kind, Rect origin,
        Future<ShareResult> Function(Rect) action) async {
      if (exporting.value != null) return;
      exporting.value = kind;
      try {
        final r = await action(origin);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
              SnackBar(content: Text(shareResultMessage(r, what: '航行記録'))));
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

    Future<void> save(Session updated, String failure) async {
      final previous = session;
      onSessionChanged(updated);
      try {
        await store.saveSession(updated);
      } catch (_) {
        onSessionChanged(previous);
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(failure)));
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

    final busy = exporting.value != null || sharingDiagnostics;
    Widget progress() => const SizedBox.square(
        dimension: 18, child: CircularProgressIndicator(strokeWidth: 2));
    final sharedAt = session.diagnosticsSharedAt;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      RecordCard(
        palette: p,
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Builder(builder: (b) {
            return FilledButton.icon(
              key: const Key('record-tools-send-log'),
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48)),
              icon: sharingDiagnostics
                  ? progress()
                  : const Icon(Icons.outgoing_mail),
              label: Text(sharingDiagnostics ? '診断ZIPを作成中…' : '診断ログを送る（開発用）'),
              onPressed:
                  busy ? null : () => onShareDiagnostics(shareOriginOf(b)),
            );
          }),
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Row(children: [
              Expanded(
                child: Text(
                  sharedAt == null
                      ? '未送信'
                      : '送信済み ${sharedAt.month}/${sharedAt.day} '
                          '${sharedAt.hour.toString().padLeft(2, '0')}:'
                          '${sharedAt.minute.toString().padLeft(2, '0')}',
                  style: TextStyle(fontSize: 12, color: p.textSub),
                ),
              ),
              // 送り直したい・送れていなかったときのため。
              if (sharedAt != null)
                TextButton(
                  onPressed: () => save(
                      session.copyWith(diagnosticsSharedAt: () => null),
                      '送信済みの印を外せませんでした。'),
                  child: const Text('未送信に戻す'),
                ),
            ]),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: Builder(builder: (b) {
                return OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
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
                          shareOriginOf(b),
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
                        shareOriginOf(b),
                        (rect) => exporter.shareAsCsv(session,
                            sharePositionOrigin: rect))),
              );
            }),
          ]),
        ]),
      ),
      AlertReviewCard(
        session: session,
        onSeekTo: onSeekTo,
        onRate: (e, rating) {
          final ratings = Map<String, String>.from(session.alertEpisodeRatings);
          if (rating == null) {
            ratings.remove(e.id);
          } else {
            ratings[e.id] = rating.name;
          }
          unawaited(save(session.copyWith(alertEpisodeRatings: ratings),
              '警告の評価を保存できませんでした。'));
        },
        onRateOverall: (rating) => unawaited(save(
            session.copyWith(alertOverallRating: () => rating?.name),
            '警告の評価を保存できませんでした。')),
      ),
      RecordCard(
        palette: p,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFE57373),
            side: const BorderSide(color: Color(0xFFE57373)),
            minimumSize: const Size.fromHeight(48),
          ),
          icon: const Icon(Icons.delete_outline),
          label: const Text('この記録を削除'),
          onPressed: busy ? null : delete,
        ),
      ),
    ]);
  }
}

/// 人が「適切だったか」を判断できる警告の種類(危険区域の種類と他艇)。
///
/// GPS途絶・位置共有不可・処理停止などのシステム系は対象にしない。
/// 1練習で数百件出ることがあり(2026-08-06 実測で最大750件)、
/// 件数は診断ZIPに入っているので、人が1件ずつ見る意味が無い。
final Set<String> rateableAlertCategories = {
  for (final k in StaticObstacleKind.values) k.name,
  'other_boat',
};

/// 警告の振り返り。種類ごとの件数の要約と、練習全体への一言評価を出す。
/// 個々の場面は、開いたときに種類ごとに危険度の高い数件だけを出す。
class AlertReviewCard extends HookWidget {
  final Session session;
  final ValueChanged<double> onSeekTo;
  final void Function(AlertEpisode, AlertEpisodeRating?) onRate;
  final ValueChanged<AlertOverallRating?> onRateOverall;

  const AlertReviewCard({
    super.key,
    required this.session,
    required this.onSeekTo,
    required this.onRate,
    required this.onRateOverall,
  });

  @override
  Widget build(BuildContext context) {
    final p = RecordPalette.of(context);
    final episodes = useMemoized(
        () => SessionAnalyzerService().detectAlertEpisodes(session.alertEvents),
        [session.alertEvents]);
    final open = useState(false);
    final showAll = useState<Set<String>>({});

    final byCategory = <String, List<AlertEpisode>>{};
    var systemCount = 0;
    for (final e in episodes) {
      if (rateableAlertCategories.contains(e.category)) {
        (byCategory[e.category] ??= []).add(e);
      } else {
        systemCount++;
      }
    }
    if (byCategory.isEmpty && systemCount == 0) return const SizedBox.shrink();
    for (final list in byCategory.values) {
      list.sort((a, b) {
        final r = b.maxRiskLevel.compareTo(a.maxRiskLevel);
        return r != 0 ? r : a.startedAt.compareTo(b.startedAt);
      });
    }
    final categories = byCategory.keys.toList()
      ..sort((a, b) => byCategory[b]!.length.compareTo(byCategory[a]!.length));
    final rated = episodes
        .where((e) => session.alertEpisodeRatings.containsKey(e.id))
        .length;
    final overall = AlertOverallRating.fromName(session.alertOverallRating);

    final eyebrow = TextStyle(
        fontSize: 12,
        letterSpacing: 1,
        fontWeight: FontWeight.w800,
        color: p.textSub);

    return RecordCard(
      palette: p,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('警告の振り返り', style: eyebrow),
        const SizedBox(height: 8),
        Text(
          categories.isEmpty
              ? '危険区域・他艇の警告はありませんでした'
              : categories
                  .map((c) =>
                      '${alertCategoryLabel(c)} ${byCategory[c]!.length}回')
                  .join('・'),
          style: TextStyle(
              fontSize: 15, fontWeight: FontWeight.w700, color: p.text),
        ),
        if (systemCount > 0)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('ほかに GPS・通信の表示 $systemCount回(評価の対象外)',
                style: TextStyle(fontSize: 12, color: p.textSub)),
          ),
        if (categories.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('今日の警告は', style: TextStyle(fontSize: 13, color: p.text)),
          const SizedBox(height: 4),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final r in AlertOverallRating.values)
              ChoiceChip(
                label: Text(r.displayLabel),
                selected: overall == r,
                onSelected: (on) => onRateOverall(on ? r : null),
              ),
          ]),
          const SizedBox(height: 4),
          TextButton.icon(
            key: const Key('alert-review-toggle'),
            style: TextButton.styleFrom(alignment: Alignment.centerLeft),
            onPressed: () => open.value = !open.value,
            icon: Icon(open.value ? Icons.expand_less : Icons.expand_more),
            label: Text(open.value
                ? '場面の一覧を閉じる'
                : '気になった場面を評価する${rated > 0 ? '（$rated件 評価済み）' : ''}'),
          ),
        ],
        if (open.value)
          for (final c in categories) ...[
            const SizedBox(height: 8),
            Text('${alertCategoryLabel(c)}（${byCategory[c]!.length}回・危険度の高い順）',
                style: eyebrow),
            for (final e in showAll.value.contains(c)
                ? byCategory[c]!
                : byCategory[c]!.take(alertEpisodePreviewPerCategory))
              _EpisodeRow(
                episode: e,
                palette: p,
                rating: AlertEpisodeRating.fromName(
                    session.alertEpisodeRatings[e.id]),
                onSeek: () => onSeekTo(
                    e.startedAt.difference(session.startedAt).inMilliseconds /
                        1000),
                onRate: (r) => onRate(e, r),
              ),
            if (!showAll.value.contains(c) &&
                byCategory[c]!.length > alertEpisodePreviewPerCategory)
              TextButton(
                style: TextButton.styleFrom(alignment: Alignment.centerLeft),
                onPressed: () => showAll.value = {...showAll.value, c},
                child: Text(
                    '残り ${byCategory[c]!.length - alertEpisodePreviewPerCategory}件を表示'),
              ),
          ],
      ]),
    );
  }
}

class _EpisodeRow extends StatelessWidget {
  final AlertEpisode episode;
  final RecordPalette palette;
  final AlertEpisodeRating? rating;
  final VoidCallback onSeek;
  final ValueChanged<AlertEpisodeRating?> onRate;

  const _EpisodeRow({
    required this.episode,
    required this.palette,
    required this.rating,
    required this.onSeek,
    required this.onRate,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final e = episode;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: onSeek,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: '${fmtClock(e.startedAt)}（${e.durationSec.round()}秒）',
                    style:
                        TextStyle(fontWeight: FontWeight.w700, color: p.text)),
                TextSpan(
                  text: [
                    '  危険度${e.maxRiskLevel}',
                    if (e.minimumDistanceMeters != null)
                      '最短${e.minimumDistanceMeters!.toStringAsFixed(1)}m',
                    if (e.hadCurrentOverlap) '重なりあり',
                  ].join('・'),
                  style: TextStyle(fontSize: 12, color: p.textSub),
                ),
                TextSpan(text: '  地図で見る ›', style: TextStyle(color: p.accent)),
              ]),
            ),
          ),
        ),
        Wrap(spacing: 4, runSpacing: 0, children: [
          for (final r in AlertEpisodeRating.values)
            ChoiceChip(
              visualDensity: VisualDensity.compact,
              labelStyle: const TextStyle(fontSize: 12),
              label: Text(r.displayLabel),
              selected: rating == r,
              onSelected: (on) => onRate(on ? r : null),
            ),
        ]),
      ]),
    );
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
      'generic' => '危険区域',
      'testZone' => 'テスト区域',
      _ => category,
    };
