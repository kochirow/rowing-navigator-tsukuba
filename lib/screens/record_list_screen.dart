import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart' hide Split;
import 'package:flutter_hooks/flutter_hooks.dart';
/* spellchecker: disable */
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../config/rowing_pace_config.dart';
import '../models/session_model.dart';
import '../services/gpx_export_service.dart';
import '../services/session_aggregator.dart';
import '../services/session_analyzer_service.dart';
import '../services/session_store_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_state_views.dart';

// # 練習記録機能
// ナビゲーション終了時に自動保存されたセッションを一覧・詳細表示する。
// - 一覧: 日時・距離・時間・平均ペース
// - 詳細: サマリー / ペース推移 / 自動検出ピース / GPX・CSV共有 / 削除
// GPXファイルはStravaにそのまま手動アップロードできる。

String formatDuration(double seconds) {
  final s = seconds.round();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  if (h > 0) {
    return '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }
  return '$m:${sec.toString().padLeft(2, '0')}';
}

String formatPace(double paceSecPer500) {
  if (paceSecPer500 <= 0 || paceSecPer500.isNaN || paceSecPer500.isInfinite) {
    return '--:--';
  }
  final s = paceSecPer500.round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

String formatDateTime(DateTime dt) {
  const weekdays = ['月', '火', '水', '木', '金', '土', '日'];
  return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/'
      '${dt.day.toString().padLeft(2, '0')}'
      '(${weekdays[dt.weekday - 1]}) '
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}';
}

class RecordListScreen extends HookConsumerWidget {
  final Future<List<Session>> Function()? sessionsLoader;
  final DateTime Function()? clock;

  const RecordListScreen({
    super.key,
    this.sessionsLoader,
    this.clock,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = useState<List<Session>>([]);
    final loading = useState(true);
    final period = useState(SessionAggregationPeriod.thisMonth);

    Future<void> loadSessions() async {
      loading.value = true;
      sessions.value = await (sessionsLoader?.call() ??
          SessionStoreService().listSessions());
      loading.value = false;
    }

    useEffect(() {
      loadSessions();
      return null;
    }, []);

    final aggregate = SessionAggregator.aggregate(
      sessions.value,
      period: period.value,
      now: clock?.call(),
    );

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('練習記録'),
      ),
      body: loading.value
          ? const AppLoadingView(message: '練習記録を読み込んでいます…')
          : sessions.value.isEmpty
              ? const AppEmptyView(
                  icon: Icons.rowing,
                  title: 'まだ記録がありません',
                  message: '航行を終了すると自動で保存されます',
                )
              : ListView(
                  padding: EdgeInsets.all(context.dimens.space3),
                  children: [
                    _PeriodSummaryCard(
                      period: period.value,
                      aggregate: aggregate,
                      onChanged: (value) => period.value = value,
                    ),
                    SizedBox(height: context.dimens.space4),
                    Text(
                      '記録一覧',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    SizedBox(height: context.dimens.space2),
                    for (final session in sessions.value)
                      _SessionListCard(
                        session: session,
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) =>
                                  RecordDetailScreen(session: session),
                            ),
                          ).then((_) => loadSessions());
                        },
                      ),
                  ],
                ),
    );
  }
}

class _PeriodSummaryCard extends StatelessWidget {
  final SessionAggregationPeriod period;
  final SessionAggregate aggregate;
  final ValueChanged<SessionAggregationPeriod> onChanged;

  const _PeriodSummaryCard({
    required this.period,
    required this.aggregate,
    required this.onChanged,
  });

  String get _emptyTitle => switch (period) {
        SessionAggregationPeriod.thisWeek => '今週の記録はありません',
        SessionAggregationPeriod.thisMonth => '今月の記録はありません',
        SessionAggregationPeriod.all => '記録はありません',
      };

  @override
  Widget build(BuildContext context) {
    final dimens = context.dimens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<SessionAggregationPeriod>(
          segments: const [
            ButtonSegment(
              value: SessionAggregationPeriod.thisWeek,
              label: Text('今週'),
            ),
            ButtonSegment(
              value: SessionAggregationPeriod.thisMonth,
              label: Text('今月'),
            ),
            ButtonSegment(
              value: SessionAggregationPeriod.all,
              label: Text('全期間'),
            ),
          ],
          selected: {period},
          onSelectionChanged: (selection) => onChanged(selection.single),
          style: const ButtonStyle(
            minimumSize: WidgetStatePropertyAll(Size.fromHeight(48)),
          ),
        ),
        SizedBox(height: dimens.space3),
        Card(
          elevation: dimens.elevationSm,
          shape: RoundedRectangleBorder(borderRadius: dimens.borderLg),
          child: aggregate.sessionCount == 0
              ? AppEmptyView(
                  icon: Icons.calendar_month_outlined,
                  title: _emptyTitle,
                  message: '期間を切り替えると、ほかの記録を確認できます',
                )
              : Padding(
                  padding: EdgeInsets.all(dimens.space4),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _SummaryStat(
                              label: '合計距離',
                              value:
                                  '${(aggregate.totalDistanceMeters / 1000).toStringAsFixed(1)} km',
                            ),
                          ),
                          SizedBox(width: dimens.space2),
                          Expanded(
                            child: _SummaryStat(
                              label: '本数',
                              value: '${aggregate.sessionCount} 本',
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: dimens.space2),
                      Row(
                        children: [
                          Expanded(
                            child: _SummaryStat(
                              label: '合計時間',
                              value: formatDuration(aggregate.totalDurationSec),
                            ),
                          ),
                          SizedBox(width: dimens.space2),
                          Expanded(
                            child: _SummaryStat(
                              label: '平均ペース',
                              value:
                                  '${formatPace(aggregate.avgPaceSecPer500)} /500m',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

class _SummaryStat extends StatelessWidget {
  final String label;
  final String value;

  const _SummaryStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.canvas,
        borderRadius: dimens.borderMd,
      ),
      child: Padding(
        padding: EdgeInsets.all(dimens.space3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: TextStyle(fontSize: 12, color: colors.textSecondary)),
            SizedBox(height: dimens.space1),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: colors.textPrimary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionListCard extends StatelessWidget {
  final Session session;
  final VoidCallback onTap;

  const _SessionListCard({required this.session, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    final summary = session.summary;
    return Card(
      margin: EdgeInsets.only(bottom: dimens.space3),
      elevation: dimens.elevationSm,
      shape: RoundedRectangleBorder(borderRadius: dimens.borderLg),
      child: InkWell(
        borderRadius: dimens.borderLg,
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(dimens.space3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.rowing, size: 20, color: colors.primary),
                  SizedBox(width: dimens.space2),
                  Expanded(
                    child: Text(
                      formatDateTime(session.startedAt),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: dimens.space2,
                      vertical: dimens.space1,
                    ),
                    decoration: BoxDecoration(
                      color: colors.primary.withValues(alpha: 0.1),
                      borderRadius: dimens.borderSm,
                    ),
                    child: Text(
                      session.boatTypeName,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: colors.primary,
                      ),
                    ),
                  ),
                ],
              ),
              if (!session.isComplete) ...[
                SizedBox(height: dimens.space2),
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: dimens.space2,
                    vertical: dimens.space1,
                  ),
                  decoration: BoxDecoration(
                    color: colors.cautionSurface,
                    borderRadius: dimens.borderSm,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.restore, size: 16, color: colors.warning),
                      SizedBox(width: dimens.space1),
                      Flexible(
                        child: Text(
                          '異常終了から復旧（最終保存時点まで）',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: colors.warning,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              SizedBox(height: dimens.space2),
              Row(
                children: [
                  _ListStat(
                    label: '距離',
                    value:
                        '${(summary.totalDistanceMeters / 1000).toStringAsFixed(1)} km',
                  ),
                  _ListStat(
                    label: '時間',
                    value: formatDuration(summary.durationSec),
                  ),
                  _ListStat(
                    label: '平均ペース',
                    value: '${formatPace(summary.avgPaceSecPer500)} /500m',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ListStat extends StatelessWidget {
  final String label;
  final String value;

  const _ListStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(fontSize: 12, color: colors.textSecondary)),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class RecordDetailScreen extends HookConsumerWidget {
  final Session session;
  final GpxExportService? exportService;
  final SessionStoreService? sessionStore;

  const RecordDetailScreen({
    super.key,
    required this.session,
    this.exportService,
    this.sessionStore,
  });

  Widget _statTile(BuildContext context, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: context.colors.canvas,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style:
                  TextStyle(fontSize: 12, color: context.colors.textSecondary)),
          const SizedBox(height: 2),
          Text(value,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentSession = useState(session);
    final exporting = useState<String?>(null);
    final exporter = useMemoized(
      () => exportService ?? GpxExportService(),
      [exportService],
    );
    final store = useMemoized(
      () => sessionStore ?? SessionStoreService(),
      [sessionStore],
    );
    final analyzer = useMemoized(SessionAnalyzerService.new);
    final activeSession = currentSession.value;
    final summary = activeSession.summary;
    final paceProfile =
        RowingPaceProfile.forBoatTypeName(activeSession.boatTypeName);
    final recalculatedSummary = useMemoized(
      () => analyzer.analyze(
        activeSession.points,
        boatTypeName: activeSession.boatTypeName,
      ),
      [activeSession],
    );
    final displaySummary =
        activeSession.points.length >= 2 ? recalculatedSummary : summary;
    // 旧バージョンで保存されたサマリーも、現在の艇種別基準で表示する。
    final workTimeSec = recalculatedSummary.movingTimeSec;
    final restTimeSec = recalculatedSummary.restTimeSec;
    final paceTrend = useMemoized(
      () => analyzer.buildPaceTrend(
        activeSession.points,
        maximumPaceSecPer500: paceProfile.displayPaceLimitSecPer500,
      ),
      [activeSession],
    );
    final pieces = recalculatedSummary.pieces;
    final alertEpisodes = useMemoized(
      () => analyzer.detectAlertEpisodes(activeSession.alertEvents),
      [activeSession],
    );

    Rect shareOrigin(BuildContext anchorContext) {
      final renderObject = anchorContext.findRenderObject();
      if (renderObject is RenderBox &&
          renderObject.hasSize &&
          renderObject.size.longestSide > 0) {
        final origin =
            renderObject.localToGlobal(Offset.zero) & renderObject.size;
        if (!origin.isEmpty) return origin;
      }
      final size = MediaQuery.sizeOf(context);
      return Rect.fromCenter(
        center: Offset(size.width / 2, size.height / 2),
        width: 1,
        height: 1,
      );
    }

    String shareResultMessage(ShareResult result) => switch (result.status) {
          ShareResultStatus.success => '共有先へ航行記録を渡しました。',
          ShareResultStatus.dismissed => '共有をキャンセルしました。',
          ShareResultStatus.unavailable => '共有シートを開きました。完了結果はこの端末から取得できません。',
        };

    Future<void> runExport(
      String kind,
      Rect origin,
      Future<ShareResult> Function(Rect origin) action,
    ) async {
      if (exporting.value != null) return;
      exporting.value = kind;
      try {
        final result = await action(origin);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(shareResultMessage(result))));
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

    Future<void> shareDiagnostics(BuildContext anchorContext) async {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('診断データを共有'),
          content: const Text(
            '診断ZIPには正確な航路、警告の発生状況、端末のOS情報、'
            '危険区域の設定が含まれます。自動送信はされません。'
            '内容を理解したうえで、共有先を自分で選んでください。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('共有先を選ぶ'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
      final origin = shareOrigin(anchorContext);
      await runExport(
        'diagnostics',
        origin,
        (rect) => exporter.shareDiagnosticPackage(
          activeSession,
          sharePositionOrigin: rect,
        ),
      );
    }

    Future<void> saveEpisodeRating(
      AlertEpisode episode,
      AlertEpisodeRating? rating,
    ) async {
      final previous = currentSession.value;
      final ratings = Map<String, String>.from(previous.alertEpisodeRatings);
      if (rating == null) {
        ratings.remove(episode.id);
      } else {
        ratings[episode.id] = rating.name;
      }
      final updated = previous.copyWith(alertEpisodeRatings: ratings);
      currentSession.value = updated;
      try {
        await store.saveSession(updated);
      } catch (_) {
        currentSession.value = previous;
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('警告の評価を保存できませんでした。')),
          );
        }
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(formatDateTime(activeSession.startedAt)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!activeSession.isComplete) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFFFB74D)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.restore, color: Color(0xFFE65100)),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '航行が正常終了しなかったため、最後のチェックポイントまでを復旧した記録です。',
                        style: TextStyle(color: Color(0xFFE65100)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            // ################ サマリー ################
            Card(
              elevation: 1,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                            child: _statTile(context, '距離',
                                '${(displaySummary.totalDistanceMeters / 1000).toStringAsFixed(2)} km')),
                        const SizedBox(width: 8),
                        Expanded(
                            child: _statTile(context, '時間',
                                formatDuration(displaySummary.durationSec))),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                            child: _statTile(context, '平均ペース',
                                '${formatPace(displaySummary.avgPaceSecPer500)} /500m')),
                        const SizedBox(width: 8),
                        Expanded(
                            child: _statTile(context, '最高速度',
                                '${displaySummary.maxSpeed.toStringAsFixed(1)} m/s')),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _statTile(
                        context,
                        '艇種 / シート',
                        '${activeSession.boatTypeName} / '
                            '${activeSession.seatPosLabel}'),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _statTile(
                            context,
                            'ワーク時間',
                            formatDuration(workTimeSec),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _statTile(
                            context,
                            '休憩時間',
                            formatDuration(restTimeSec),
                          ),
                        ),
                      ],
                    ),
                    if (summary.alertCounts.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      _statTile(
                          context,
                          '警告発生(秒)',
                          summary.alertCounts.entries
                              .map((e) => '${e.key}: ${e.value}')
                              .join('  ')),
                    ],
                  ],
                ),
              ),
            ),
            if (paceTrend.isNotEmpty) ...[
              _sectionTitle('ペース推移'),
              Card(
                elevation: 1,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '15秒の移動窓を5秒ごとに表示（${formatPace(paceProfile.displayPaceLimitSecPer500)} /500mより速い区間）',
                        style: TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 150,
                        child: CustomPaint(
                          painter: _PaceTrendPainter(paceTrend),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            // ################ 自動検出ピース ################
            if (pieces.isNotEmpty) ...[
              _sectionTitle('ピース(自動検出)'),
              Card(
                elevation: 1,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      vertical: 8.0, horizontal: 14.0),
                  child: Column(
                    children: pieces.asMap().entries.map((entry) {
                      final piece = entry.value;
                      final piecePoints = activeSession.points
                          .where((point) =>
                              !point.t.isBefore(piece.startTime) &&
                              !point.t.isAfter(piece.endTime))
                          .toList(growable: false);
                      final pieceTrend = analyzer.buildPaceTrend(
                        piecePoints,
                        maximumPaceSecPer500:
                            paceProfile.displayPaceLimitSecPer500,
                      );
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  '#${entry.key + 1}'
                                  ' ${piece.distanceMeters.round()}m'
                                  ' ${formatDuration(piece.durationSec)}',
                                  style: TextStyle(
                                      color: context.colors.textPrimary),
                                ),
                                Text(
                                  '${formatPace(piece.avgPaceSecPer500)}/500m'
                                  '${piece.avgSpm != null ? ' ${piece.avgSpm!.round()}spm' : ''}',
                                  style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                            if (pieceTrend.length >= 2) ...[
                              const SizedBox(height: 6),
                              SizedBox(
                                height: 120,
                                child: CustomPaint(
                                  painter: _PaceTrendPainter(pieceTrend),
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ],
            if (alertEpisodes.isNotEmpty) ...[
              _sectionTitle('警告エピソード'),
              const Text(
                '航跡の時刻と関連付けています。現地で感じた内容を選ぶと端末内の記録へ保存されます。',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 8),
              for (final episode in alertEpisodes)
                Builder(builder: (context) {
                  final point = analyzer.nearestTrackPoint(
                    activeSession.points,
                    episode.startedAt,
                  );
                  final rating = AlertEpisodeRating.fromName(
                    activeSession.alertEpisodeRatings[episode.id],
                  );
                  return Card(
                    elevation: 1,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '${_alertCategoryLabel(episode.category)}  '
                            '${_formatClock(episode.startedAt)}'
                            '（${episode.durationSec.round()}秒）',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            [
                              '最大危険度: ${episode.maxRiskLevel}',
                              if (episode.minimumDistanceMeters != null)
                                '最短距離: '
                                    '${episode.minimumDistanceMeters!.toStringAsFixed(1)}m',
                              if (episode.hadCurrentOverlap) '領域重なりあり',
                            ].join('  '),
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.black54,
                            ),
                          ),
                          if (point != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              '発生位置: '
                              '${point.lat.toStringAsFixed(5)}, '
                              '${point.lng.toStringAsFixed(5)}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.black54,
                              ),
                            ),
                          ],
                          const SizedBox(height: 8),
                          DropdownButtonFormField<AlertEpisodeRating>(
                            initialValue: rating,
                            decoration: const InputDecoration(
                              labelText: 'この警告を評価',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            items: [
                              for (final value in AlertEpisodeRating.values)
                                DropdownMenuItem(
                                  value: value,
                                  child: Text(value.displayLabel),
                                ),
                            ],
                            onChanged: (value) =>
                                saveEpisodeRating(episode, value),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  // 削除は誤タップしにくいようアイコンのみ・端に置く
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFC62828),
                      side: const BorderSide(color: Color(0xFFC62828)),
                      minimumSize: const Size(52, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    onPressed: exporting.value != null
                        ? null
                        : () async {
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (dialogContext) => AlertDialog(
                                title: const Text('記録の削除'),
                                content:
                                    const Text('この記録を削除しますか?この操作は取り消せません。'),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(dialogContext).pop(false),
                                    child: const Text('キャンセル'),
                                  ),
                                  FilledButton(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: const Color(0xFFC62828),
                                    ),
                                    onPressed: () =>
                                        Navigator.of(dialogContext).pop(true),
                                    child: const Text('削除する'),
                                  ),
                                ],
                              ),
                            );
                            if (confirmed != true) return;
                            await store.deleteSession(activeSession.id);
                            if (context.mounted) Navigator.pop(context);
                          },
                    child: const Icon(Icons.delete_outline),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Builder(builder: (buttonContext) {
                      return FilledButton.icon(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                        icon: exporting.value == 'gpx'
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.share),
                        label: Text(
                          exporting.value == 'gpx' ? '作成中…' : 'GPX(Strava用)',
                        ),
                        onPressed: exporting.value != null
                            ? null
                            : () {
                                final origin = shareOrigin(buttonContext);
                                unawaited(runExport(
                                  'gpx',
                                  origin,
                                  (rect) => exporter.shareAsGpx(
                                    activeSession,
                                    sharePositionOrigin: rect,
                                  ),
                                ));
                              },
                      );
                    }),
                  ),
                  const SizedBox(width: 8),
                  Builder(builder: (buttonContext) {
                    return OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                      icon: exporting.value == 'csv'
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.table_chart_outlined),
                      label: Text(
                        exporting.value == 'csv' ? '作成中…' : 'CSV',
                      ),
                      onPressed: exporting.value != null
                          ? null
                          : () {
                              final origin = shareOrigin(buttonContext);
                              unawaited(runExport(
                                'csv',
                                origin,
                                (rect) => exporter.shareAsCsv(
                                  activeSession,
                                  sharePositionOrigin: rect,
                                ),
                              ));
                            },
                    );
                  }),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: Builder(builder: (buttonContext) {
                  return OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    icon: exporting.value == 'diagnostics'
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.bug_report_outlined),
                    label: Text(
                      exporting.value == 'diagnostics'
                          ? '診断ZIPを作成中…'
                          : '診断データを共有',
                    ),
                    onPressed: exporting.value != null
                        ? null
                        : () => unawaited(shareDiagnostics(buttonContext)),
                  );
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatClock(DateTime time) => '${time.hour.toString().padLeft(2, '0')}:'
    '${time.minute.toString().padLeft(2, '0')}:'
    '${time.second.toString().padLeft(2, '0')}';

String _alertCategoryLabel(String category) => switch (category) {
      'shore' => '岸',
      'bridge' => '橋',
      'bridgePier' => '橋脚',
      'island' => '中州',
      'driftwood' => '流木',
      'curve' => 'カーブ',
      'reverse' => '逆走注意',
      'other_boat' => '他艇',
      'other_boat_track_lost' => '他艇情報途絶',
      'gps_unavailable' => 'GPS利用不可',
      _ => category,
    };

class _PaceTrendPainter extends CustomPainter {
  final List<PaceTrendPoint> points;

  const _PaceTrendPainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    final values = points
        .map((point) => point.paceSecPer500)
        .where((value) => value.isFinite && value > 0)
        .toList(growable: false);
    if (values.length < 2) return;
    var minimum = values.first;
    var maximum = values.first;
    for (final value in values.skip(1)) {
      if (value < minimum) minimum = value;
      if (value > maximum) maximum = value;
    }
    // ペース目盛りは常に5秒単位。数秒の差も読める範囲に丸める。
    minimum = (minimum / 5).floorToDouble() * 5;
    maximum = (maximum / 5).ceilToDouble() * 5;
    if (maximum - minimum < 10) {
      minimum -= 5;
      maximum += 5;
    }

    const labelWidth = 42.0;
    const bottomPadding = 12.0;
    final chart = Rect.fromLTWH(
      labelWidth,
      4,
      size.width - labelWidth - 4,
      size.height - bottomPadding - 4,
    );
    final gridPaint = Paint()
      ..color = Colors.black12
      ..strokeWidth = 1;
    final tickCount = ((maximum - minimum) / 5).round();
    for (var index = 0; index <= tickCount; index++) {
      final pace = minimum + index * 5;
      final y =
          chart.top + chart.height * (pace - minimum) / (maximum - minimum);
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), gridPaint);
    }

    final linePaint = Paint()
      ..color = const Color(0xFF1565C0)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    final startTime = points.first.t;
    final endTime = points.last.t;
    final durationMillis = max(1, endTime.difference(startTime).inMilliseconds);
    DateTime? previousTime;
    for (var index = 0; index < points.length; index++) {
      final x = chart.left +
          chart.width *
              points[index].t.difference(startTime).inMilliseconds /
              durationMillis;
      final normalized = (values[index] - minimum) / (maximum - minimum);
      final y = chart.top + chart.height * normalized;
      final isGap = previousTime != null &&
          points[index].t.difference(previousTime) >
              const Duration(seconds: 10);
      if (index == 0 || isGap) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
      previousTime = points[index].t;
    }
    canvas.drawPath(path, linePaint);

    void drawLabel(double pace, double y) {
      final painter = TextPainter(
        text: TextSpan(
          text: formatPace(pace),
          // グラフ軸の目盛り。ラベル幅が狭く、他のUI文言と同じ12pxでは
          // 隣の目盛りと重なるため、ここだけ11pxを許容する。
          style: const TextStyle(fontSize: 11, color: Colors.black54),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: labelWidth - 4);
      painter.paint(canvas, Offset(0, y - painter.height / 2));
    }

    // 速いペースを上、遅いペースを下に表示する。目盛線は5秒ごと。
    for (var index = 0; index <= tickCount; index++) {
      // ラベルが過密な場合も、線は5秒刻みのままラベルだけ間引く。
      if (tickCount > 7 && index.isOdd) continue;
      final pace = minimum + index * 5;
      final y = chart.top + chart.height * index / tickCount;
      drawLabel(pace, y);
    }
  }

  @override
  bool shouldRepaint(covariant _PaceTrendPainter oldDelegate) =>
      oldDelegate.points != points;
}
