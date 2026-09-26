import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/session_model.dart';
import '../../services/gpx_export_service.dart';
import '../../services/preset_obstacle_service.dart';
import '../../services/session_store_service.dart';
import '../../theme/record_palette.dart';
import '../../types/boat_type.dart';
import 'bout_direction.dart';
import 'replay_analysis.dart';
import 'replay_controller.dart';
import 'replay_format.dart';
import 'widgets/detail_sections.dart';
import 'widgets/metric_chart.dart';
import 'widgets/answer_overlay.dart';
import 'widgets/record_tools.dart';
import 'widgets/replay_map.dart';
import 'widgets/replay_timeline.dart';
import 'widgets/selection_card.dart';
import 'widgets/set_cards.dart';
import 'widgets/set_table.dart';

// # 練習記録リプレイ（記録の詳細画面）
//
// 地図・時間軸・数値・グラフが「時刻1つ・区間1つ」を共有する（設計書 芯1）。
// 上段（地図・再生・時間軸・その瞬間の値）は固定し、下段だけスクロールする。
// 表示専用で、安全経路には何も戻さない。航行中はメニューに出ない（home_map_screen）。
// 仕様: docs/design_notes/2026-09-24_練習記録リプレイ_全面再設計.md

class RecordReplayScreen extends HookWidget {
  final Session session;
  final GpxExportService? exportService;
  final SessionStoreService? sessionStore;

  /// テストで地図（プラットフォームビュー）の代わりに置く部品。
  @visibleForTesting
  final Widget Function(Widget overlay)? mapBuilderForTest;

  const RecordReplayScreen({
    super.key,
    required this.session,
    this.exportService,
    this.sessionStore,
    this.mapBuilderForTest,
  });

  @override
  Widget build(BuildContext context) {
    final p = RecordPalette.of(context);
    final current = useState(session);
    // 解析は開いたときに1回だけ（航跡は評価の保存では変わらない）。
    final analysis =
        useMemoized(() => ReplayAnalysis.compute(session), [session.id]);
    final controller =
        useMemoized(() => ReplayController(analysis), [analysis]);
    useEffect(() => controller.dispose, [controller]);
    useListenable(controller);
    useEffect(() {
      PresetObstacleService().loadChannelCenterlines().then((lines) {
        controller.setDirections(BoutDirectionResolver(
            {for (final e in lines.entries) e.key: e.value.vertices}));
      }).catchError((Object error) {
        // 向きが出ないだけで、記録の表示は続ける。
        debugPrint('Record replay: directions unavailable: $error');
      });
      return null;
    }, [controller]);
    final exporter =
        useMemoized(() => exportService ?? GpxExportService(), [exportService]);
    final store = useMemoized(
        () => sessionStore ?? SessionStoreService(), [sessionStore]);
    final scroll = useScrollController();
    final media = MediaQuery.of(context);
    // 地図は画面の端まで敷き、下端に答えの数字を重ねる(旧版の迫力×視線の順番)。
    final mapHeight =
        (media.size.height * 0.44).clamp(280.0, 420.0) + media.padding.top;

    void scrollToTop() => scroll.animateTo(0,
        duration: const Duration(milliseconds: 300), curve: Curves.easeOut);

    Future<void> shareText() async {
      final c = controller;
      final st = c.selectionStats;
      final s = current.value;
      final head =
          '${s.startedAt.month}/${s.startedAt.day} ${_boatLabel(s.boatTypeName)}';
      final set = c.selectedSet;
      final String text;
      if (set != null) {
        final unit = set.intensity.unit;
        text =
            '$head ${set.index + 1}セット目 ${set.intensity.label} ${set.bouts.length}$unit\n'
            '平均 ${fmtPace(st.paceSecPer500)}/500m SR${st.averageSpm?.round() ?? '--'}'
            ' DPS ${st.averageDps?.toStringAsFixed(1) ?? '--'}m'
            '${set.bouts.length > 1 ? '\n各$unit: ${set.bouts.map((b) => fmtPace(b.stats.paceSecPer500)).join(' / ')}' : ''}';
      } else {
        final laps = c.analysis.analyzer
            .laps(c.selection)
            .where((l) => !l.isPartial)
            .map((l) => fmtDuration(l.range.duration))
            .join(' / ');
        text =
            '$head ${fmtDuration(c.selection.start)}〜${fmtDuration(c.selection.end)}\n'
            '${st.distance.round()}m 平均 ${fmtPace(st.paceSecPer500)}/500m'
            ' SR${st.averageSpm?.round() ?? '--'} DPS ${st.averageDps?.toStringAsFixed(1) ?? '--'}m'
            '${laps.isEmpty ? '' : '\n250mラップ: $laps'}';
      }
      await SharePlus.instance.share(ShareParams(text: text));
    }

    final s = current.value;
    final header = SafeArea(
      bottom: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(4, 4, 14, 26),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              p.background.withValues(alpha: 0.85),
              p.background.withValues(alpha: 0)
            ],
          ),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          IconButton(
            tooltip: '戻る',
            icon: Icon(Icons.arrow_back, color: p.text),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_dateLabel(s.startedAt),
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: p.textSub)),
                    Text('${_boatLabel(s.boatTypeName)} ・ ${s.seatPosLabel}',
                        style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            color: p.text)),
                    Text(
                      '${fmtDistance(analysis.track.totalDistance)} ・ '
                      '${fmtDuration(analysis.track.duration)} ・ ${analysis.sets.length}セット',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: p.textSub),
                    ),
                  ]),
            ),
          ),
        ]),
      ),
    );

    return Scaffold(
      backgroundColor: p.background,
      body: Column(children: [
        SizedBox(
          height: mapHeight,
          child: mapBuilderForTest?.call(header) ??
              ReplayMap(
                controller: controller,
                overlay: header,
                bottomOverlay: AnswerOverlay(controller: controller),
              ),
        ),
        _Player(controller: controller, palette: p),
        // 再生位置の値は、動かしたときだけ地図の下端(答えの上)に出す。
        ReplayTimeline(controller: controller),
        Expanded(
          child: ListView(
            key: const Key('record-replay-scroll'),
            controller: scroll,
            padding: EdgeInsets.only(bottom: 40 + media.padding.bottom),
            children: [
              if (!s.isComplete)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                  child: Text(
                    '航行が正常終了しなかったため、最後のチェックポイントまでを復旧した記録です。',
                    style: TextStyle(fontSize: 12, color: p.metricSpm),
                  ),
                ),
              SetCards(controller: controller),
              SelectionCard(controller: controller, onShare: shareText),
              MetricChartCard(controller: controller),
              DetailSections(controller: controller),
              SetTable(controller: controller, onRowTap: scrollToTop),
              FastestEfforts(controller: controller, onTap: scrollToTop),
              FusionReportCard(controller: controller),
              RecordTools(
                session: s,
                onSessionChanged: (v) => current.value = v,
                exporter: exporter,
                store: store,
                onSeekTo: (t) {
                  controller.seek(t);
                  scrollToTop();
                },
              ),
            ],
          ),
        ),
      ]),
    );
  }

  static String _dateLabel(DateTime t) {
    const wd = ['月', '火', '水', '木', '金', '土', '日'];
    return '${t.year}年${t.month}月${t.day}日(${wd[t.weekday - 1]}) '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  static String _boatLabel(String name) => boatTypeDisplayLabel(name);
}

class _Player extends StatelessWidget {
  final ReplayController controller;
  final RecordPalette palette;
  const _Player({required this.controller, required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final c = controller;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
      child: Row(children: [
        Material(
          color: p.accent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: c.togglePlay,
            child: SizedBox.square(
              dimension: 46,
              child: Icon(c.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: p.onAccent, semanticLabel: c.isPlaying ? '停止' : '再生'),
            ),
          ),
        ),
        const SizedBox(width: 10),
        // 倍速は1つのボタンで順に切り替える(操作は畳む)。
        Material(
          color: p.surfaceHigh,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () {
              const speeds = ReplayController.playbackSpeeds;
              final i = speeds.indexOf(c.speed);
              c.setSpeed(speeds[(i + 1) % speeds.length]);
            },
            child: Container(
              height: 40,
              constraints: const BoxConstraints(minWidth: 56),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('×${c.speed}',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: p.text)),
            ),
          ),
        ),
        const Spacer(),
        if (c.isTimelineZoomed)
          GestureDetector(
            onTap: c.resetTimeline,
            child: Text('時間軸を全体に戻す',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: p.accent)),
          ),
      ]),
    );
  }
}
