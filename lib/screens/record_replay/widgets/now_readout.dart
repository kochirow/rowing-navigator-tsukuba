import 'package:flutter/material.dart';

import '../../../config/record_replay_config.dart';
import '../../../theme/record_palette.dart';
import '../replay_controller.dart';
import '../replay_format.dart';

/// その瞬間の値（経過・時刻 / /500m / SR / DPS）。時間軸のすぐ下に常に出す。
class NowReadout extends StatelessWidget {
  final ReplayController controller;
  const NowReadout({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final p = RecordPalette.of(context);
    final tr = controller.track;
    final i = tr.indexAt(controller.cursor);
    final v = tr.isEmpty ? 0.0 : tr.speed[i];
    final moving = v >= replayMovingSpeedMps;
    final working = v >= replayWorkSpeedMps;
    final clock = controller.analysis.session.startedAt
        .add(Duration(milliseconds: (controller.cursor * 1000).round()));
    final spm = tr.isEmpty ? null : tr.spm[i];
    final dps = tr.isEmpty ? null : tr.dpsAt(i);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
      child: Row(children: [
        Expanded(
          flex: 5,
          child: _Cell(
            value: fmtDuration(controller.cursor),
            label: '経過 ・ 時刻 ${fmtClock(clock)}',
            palette: p,
            size: 20,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          flex: 4,
          child: _Cell(
            value: moving ? fmtPace(500 / v) : '--',
            label: moving ? (working ? '/500m' : '/500m（パドル）') : '停止中',
            accent: p.metricPace,
            palette: p,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          flex: 3,
          child: _Cell(
            value: working && spm != null ? '${spm.round()}' : '--',
            label: 'SR',
            accent: p.metricSpm,
            palette: p,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          flex: 3,
          child: _Cell(
            value: dps != null ? dps.toStringAsFixed(1) : '--',
            label: 'DPS m',
            accent: p.metricDps,
            palette: p,
          ),
        ),
      ]),
    );
  }
}

class _Cell extends StatelessWidget {
  final String value;
  final String label;
  final Color? accent;
  final RecordPalette palette;
  final double size;

  const _Cell({
    required this.value,
    required this.label,
    required this.palette,
    this.accent,
    this.size = 22,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(height: 3, color: accent ?? Colors.transparent),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 2, 6, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: TextStyle(
                    fontSize: size,
                    fontWeight: FontWeight.w800,
                    color: palette.text,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: palette.textSub),
              ),
            ],
          ),
        ),
      ]),
    );
  }
}
