import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Split;
import 'package:flutter_hooks/flutter_hooks.dart';
/* spellchecker: disable */
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../models/session_model.dart';
import '../services/session_aggregator.dart';
import '../services/session_store_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_state_views.dart';
import 'record_replay/record_replay_screen.dart';
import 'record_replay/replay_analysis.dart';
import 'record_replay/replay_format.dart';

// # 練習記録機能
// ナビゲーション終了時に自動保存されたセッションを一覧・詳細表示する。
// - 一覧: 日時・距離・時間・平均 /500m・セットの要約
// - 詳細: record_replay/record_replay_screen.dart（地図・時間軸・セット・グラフ・共有・削除）
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
                                  RecordReplayScreen(session: session),
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
                              label: '平均 /500m',
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
                    label: '平均 /500m',
                    value: '${formatPace(summary.avgPaceSecPer500)} /500m',
                  ),
                ],
              ),
              _SetSummaryLine(session: session),
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

/// 一覧のカードに出すセットの要約（例「UT 33:14 ・ ハイレート 5本」）。
///
/// 解析は重いので、カードが画面に出たときに別 isolate で1回だけ行い、結果を覚えておく。
class _SetSummaryLine extends StatefulWidget {
  final Session session;
  const _SetSummaryLine({required this.session});

  static final _cache = <String, Future<String>>{};

  @override
  State<_SetSummaryLine> createState() => _SetSummaryLineState();
}

class _SetSummaryLineState extends State<_SetSummaryLine> {
  late final Future<String> _summary = _SetSummaryLine._cache.putIfAbsent(
      widget.session.id, () => compute(_summarizeSets, widget.session));

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _summary,
      builder: (context, snap) {
        final text = snap.data;
        if (text == null || text.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: EdgeInsets.only(top: context.dimens.space2),
          child: Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: context.colors.textSecondary,
            ),
          ),
        );
      },
    );
  }
}

String _summarizeSets(Session session) {
  if (session.points.length < 2) return '';
  final a = ReplayAnalysis.compute(session);
  return a.sets.map((s) {
    final head = s.intensity.label;
    return s.bouts.length > 1 && s.intensity.unit == '本'
        ? '$head ${s.bouts.length}本'
        : '$head ${fmtDuration(s.rowingSec)}';
  }).join(' ・ ');
}
