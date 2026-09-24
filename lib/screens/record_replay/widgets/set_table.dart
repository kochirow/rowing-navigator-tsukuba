import 'package:flutter/material.dart';

import '../../../services/record/replay_track.dart';
import '../../../services/record/training_set_detector.dart';
import '../../../theme/record_palette.dart';
import '../replay_controller.dart';
import '../replay_format.dart';
import 'selection_card.dart';

/// 各セットの表（自動検出）。行をタップするとそのセットを選ぶ。
class SetTable extends StatelessWidget {
  final ReplayController controller;
  final VoidCallback onRowTap;
  const SetTable({super.key, required this.controller, required this.onRowTap});

  @override
  Widget build(BuildContext context) {
    final p = RecordPalette.of(context);
    final sets = controller.analysis.sets;
    final head =
        TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: p.textMute);
    final cell = TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: p.textSub,
        fontFeatures: const [FontFeature.tabularFigures()]);
    final selected = controller.selectedSet;
    Widget row(List<Widget> cells, {VoidCallback? onTap, bool on = false}) =>
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
            decoration: BoxDecoration(
              color: on ? p.surfaceHigh : null,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              for (var k = 0; k < cells.length; k++)
                Expanded(
                    flex: const [3, 12, 12, 5, 6, 7, 9][k], child: cells[k]),
            ]),
          ),
        );
    Widget r(String s, TextStyle st) =>
        Text(s, textAlign: TextAlign.right, style: st);
    return RecordCard(
      palette: p,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('各セット（自動検出）',
            style: TextStyle(
                fontSize: 12,
                letterSpacing: 1,
                fontWeight: FontWeight.w800,
                color: p.textSub)),
        const SizedBox(height: 8),
        if (sets.isEmpty)
          Text('一定のペースで漕いだ区間は見つかりませんでした。',
              style: TextStyle(fontSize: 12, color: p.textSub))
        else ...[
          row([
            const SizedBox(),
            Text('種類', style: head),
            r('平均 /500m', head),
            r('SR', head),
            r('DPS', head),
            r('距離', head),
            r('漕いだ時間', head),
          ]),
          for (final s in sets)
            row(
              [
                Text('${s.index + 1}', style: cell.copyWith(color: p.textMute)),
                Text.rich(
                  TextSpan(children: [
                    TextSpan(text: s.intensity.label),
                    if (s.intensity == TrainingIntensity.highRate)
                      TextSpan(
                          text: ' ${s.bouts.length}本',
                          style: TextStyle(fontSize: 12, color: p.textMute)),
                  ]),
                  maxLines: 1,
                  style: cell.copyWith(
                      fontWeight: FontWeight.w800,
                      color: p.intensity(s.intensity.index)),
                ),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: s.stats.paceSecPer500 == null
                          ? p.textMute
                          : RecordPalette.paceRamp(controller.analysis
                              .paceRatio(s.stats.paceSecPer500!)),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(fmtPace(s.stats.paceSecPer500),
                      style: cell.copyWith(
                          fontWeight: FontWeight.w800, color: p.text)),
                ]),
                r('${s.stats.averageSpm?.round() ?? '--'}', cell),
                r(s.stats.averageDps?.toStringAsFixed(1) ?? '--', cell),
                r(
                    s.stats.distance >= 1000
                        ? '${(s.stats.distance / 1000).toStringAsFixed(1)}k'
                        : '${s.stats.distance.round()}',
                    cell),
                r(fmtDuration(s.rowingSec),
                    cell.copyWith(fontWeight: FontWeight.w800, color: p.text)),
              ],
              on: identical(selected, s),
              onTap: () {
                controller.selectSet(s);
                onRowTap();
              },
            ),
        ],
      ]),
    );
  }
}

/// この日の最速（500m / 1000m / 2000m）。本・区間の中だけで探す。
class FastestEfforts extends StatelessWidget {
  final ReplayController controller;
  final VoidCallback onTap;
  const FastestEfforts(
      {super.key, required this.controller, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = RecordPalette.of(context);
    final a = controller.analysis;
    return RecordCard(
      palette: p,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('この日の最速',
            style: TextStyle(
                fontSize: 12,
                letterSpacing: 1,
                fontWeight: FontWeight.w800,
                color: p.textSub)),
        const SizedBox(height: 10),
        Row(children: [
          for (final meters in const [500.0, 1000.0, 2000.0]) ...[
            if (meters != 500) const SizedBox(width: 8),
            Expanded(
              child: Builder(builder: (context) {
                final ReplayRange? best =
                    a.analyzer.fastest(meters, a.allBoutRanges);
                return Material(
                  color: p.surfaceHigh,
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: best == null
                        ? null
                        : () {
                            controller.select(best);
                            onTap();
                          },
                    child: Opacity(
                      opacity: best == null ? 0.4 : 1,
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('最速 ${meters.round()}m',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: p.textSub)),
                              const SizedBox(height: 3),
                              Text(
                                  best == null
                                      ? '--'
                                      : fmtDuration(best.duration),
                                  style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w800,
                                      color: p.text,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures()
                                      ])),
                              Text(
                                  best == null
                                      ? '対象なし'
                                      : '${fmtPace(best.duration * 500 / meters)} /500m',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: p.textSub)),
                            ]),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ],
        ]),
      ]),
    );
  }
}
