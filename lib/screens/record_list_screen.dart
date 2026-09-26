import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Split;
import 'package:flutter_hooks/flutter_hooks.dart';
/* spellchecker: disable */
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../models/session_model.dart';
import '../services/session_aggregator.dart';
import '../services/session_list_grouping.dart';
import '../services/session_store_service.dart';
import '../theme/app_theme.dart';
import '../types/boat_type.dart';
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
                    SizedBox(height: context.dimens.space3),
                    _WeeklyBars(
                      sessions: sessions.value,
                      period: period.value,
                      now: clock?.call() ?? DateTime.now(),
                    ),
                    SizedBox(height: context.dimens.space4),
                    // 一覧は期間の切替に関係なく全件。上の集計と範囲が違うことを
                    // 見出しの横に書いておく。
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          '記録一覧',
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                        ),
                        SizedBox(width: context.dimens.space2),
                        Text(
                          '全期間・${sessions.value.length}件',
                          style: TextStyle(
                            fontSize: 13,
                            color: context.colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: context.dimens.space2),
                    ..._groupedSessionList(
                      context,
                      sessions.value,
                      onOpen: (session) {
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
                  // 下の一覧は期間によらず全件を出している(集計だけが期間で変わる)。
                  // 「切り替えると見られる」と書くと、一覧まで絞られていると誤読される。
                  message: 'これまでの記録は下の一覧から開けます',
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
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 航跡の小さな絵。同じ見た目のカードが続いても、どの日か見分けやすい。
              _TrackThumb(points: session.points, color: colors.primary),
              SizedBox(width: dimens.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
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
                            boatTypeDisplayLabel(session.boatTypeName),
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
                            Icon(Icons.restore,
                                size: 16, color: colors.warning),
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
                          value:
                              '${formatPace(summary.avgPaceSecPer500)} /500m',
                        ),
                      ],
                    ),
                    _SetSummaryLine(session: session),
                  ],
                ),
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

/// 月ごとの見出しで区切り、短い記録(1分未満・100m未満)は下にまとめて畳む(消さない)。
List<Widget> _groupedSessionList(
  BuildContext context,
  List<Session> sessions, {
  required void Function(Session) onOpen,
}) {
  final colors = context.colors;
  final normal = [
    for (final s in sessions)
      if (!isShortSession(s)) s
  ];
  final short = [
    for (final s in sessions)
      if (isShortSession(s)) s
  ];
  final widgets = <Widget>[];
  String? month;
  for (final s in normal) {
    final d = s.startedAt.toLocal();
    final key = '${d.year}年${d.month}月';
    if (key != month) {
      month = key;
      final inMonth = normal.where((x) {
        final t = x.startedAt.toLocal();
        return t.year == d.year && t.month == d.month;
      });
      final km =
          inMonth.fold<double>(0, (a, x) => a + x.summary.totalDistanceMeters) /
              1000;
      widgets.add(Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
        child: Row(children: [
          Text(key,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: colors.textSecondary)),
          const Spacer(),
          Text('${inMonth.length}本 ・ ${km.toStringAsFixed(1)} km',
              style: TextStyle(fontSize: 13, color: colors.textSecondary)),
        ]),
      ));
    }
    widgets.add(_SessionListCard(session: s, onTap: () => onOpen(s)));
  }
  if (short.isNotEmpty) {
    widgets.add(Card(
      margin: const EdgeInsets.only(top: 4),
      child: ExpansionTile(
        title: Text('短い記録 ${short.length}件'),
        subtitle: const Text('1分未満・100m未満'),
        children: [
          for (final s in short)
            ListTile(
              title: Text(formatDateTime(s.startedAt)),
              trailing: Text(
                '${formatDuration(s.summary.durationSec)} ・ '
                '${s.summary.totalDistanceMeters.round()} m',
              ),
              onTap: () => onOpen(s),
            ),
        ],
      ),
    ));
  }
  return widgets;
}

/// 直近8週の距離の棒。選んでいる期間の週だけアクセントの色にする。
class _WeeklyBars extends StatelessWidget {
  const _WeeklyBars({
    required this.sessions,
    required this.period,
    required this.now,
  });

  final List<Session> sessions;
  final SessionAggregationPeriod period;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final totals = weeklyDistances(sessions, now: now);
    final starts = weekStarts(now);
    final max = totals.fold<double>(0, (a, b) => b > a ? b : a);
    bool inPeriod(DateTime monday) => switch (period) {
          SessionAggregationPeriod.all => true,
          SessionAggregationPeriod.thisWeek => monday == starts.last,
          SessionAggregationPeriod.thisMonth =>
            monday.add(const Duration(days: 6)).month == now.month ||
                monday.month == now.month,
        };
    return Semantics(
      label: '直近8週の距離',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Text('週ごとの距離',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: colors.textSecondary)),
            const Spacer(),
            Text(
              '直近8週 ${(totals.fold<double>(0, (a, b) => a + b) / 1000).toStringAsFixed(1)} km',
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ]),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < totals.length; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 棒の高さの枠を固定し、下に日付を置く(文字を大きくする設定でも溢れない)。
                        SizedBox(
                          height: 44,
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              height: max <= 0
                                  ? 3
                                  : (totals[i] / max * 44).clamp(3.0, 44.0),
                              decoration: BoxDecoration(
                                color: inPeriod(starts[i])
                                    ? colors.primary
                                    : colors.textDisabled,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          i == totals.length - 1
                              ? '今週'
                              : '${starts[i].month}/${starts[i].day}',
                          style: TextStyle(
                              fontSize: 11, color: colors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 航跡の小さな絵(表示専用)。点が多いときは間引く。
class _TrackThumb extends StatelessWidget {
  const _TrackThumb({required this.points, required this.color});

  final List<TrackPoint> points;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: points.length < 2
            ? Icon(Icons.rowing, color: color)
            : CustomPaint(painter: _ThumbPainter(points, color)),
      );
}

class _ThumbPainter extends CustomPainter {
  _ThumbPainter(this.points, this.color);

  final List<TrackPoint> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final step = (points.length / 200).ceil().clamp(1, 1 << 20);
    final pts = [for (var i = 0; i < points.length; i += step) points[i]];
    var minLat = pts.first.lat, maxLat = minLat;
    var minLng = pts.first.lng, maxLng = minLng;
    for (final p in pts) {
      if (p.lat < minLat) minLat = p.lat;
      if (p.lat > maxLat) maxLat = p.lat;
      if (p.lng < minLng) minLng = p.lng;
      if (p.lng > maxLng) maxLng = p.lng;
    }
    // 経度は緯度で縮めて、形がつぶれないようにする。
    final kx = 0.82; // cos(35°)付近(桜川・霞ヶ浦)
    final w = (maxLng - minLng) * kx, h = maxLat - minLat;
    final span = w > h ? w : h;
    if (span <= 0) return;
    const pad = 8.0;
    final scale = (size.width - pad * 2) / span;
    final ox = (size.width - w * scale) / 2, oy = (size.height - h * scale) / 2;
    final path = Path();
    for (var i = 0; i < pts.length; i++) {
      final x = ox + (pts[i].lng - minLng) * kx * scale;
      final y = oy + (maxLat - pts[i].lat) * scale;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _ThumbPainter old) => old.points != points;
}
