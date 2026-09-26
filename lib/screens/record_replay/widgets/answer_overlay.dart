import 'package:flutter/material.dart';

import '../../../config/record_replay_config.dart';
import '../../../theme/record_palette.dart';
import '../replay_controller.dart';
import '../replay_format.dart';

/// 地図の下端に重ねる「答え」(選んだ区間の /500m・SR・DPS と要約)。
///
/// 旧版の迫力(全面の地図・太い数字、Strava の活動ページの型)と、答えを先に
/// 置く視線の順番を両立させる(2026-09-26 利用者)。目は 見出し→地図→数字 と
/// 上から下へ流れる。区間を選ぶとここが書き換わる。競技用語で書く(DPS・SR)。
class AnswerOverlay extends StatelessWidget {
  const AnswerOverlay({super.key, required this.controller});

  final ReplayController controller;

  @override
  Widget build(BuildContext context) {
    final p = RecordPalette.of(context);
    final c = controller;
    final st = c.selectionStats;
    final set = c.selectedSet;
    final whole =
        c.selection.start <= 0.5 && c.selection.end >= c.duration - 0.5;
    final crumb = set != null
        ? '${set.index + 1}セット目 ${set.intensity.label}'
        : whole
            ? 'この日の練習'
            : '選んだ区間 ${fmtDuration(c.selection.start)}〜${fmtDuration(c.selection.end)}';
    final numStyle = TextStyle(
      color: p.text,
      fontWeight: FontWeight.w800,
      height: 1,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final sub =
        TextStyle(color: p.textSub, fontSize: 13, fontWeight: FontWeight.w700);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 40, 16, 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            p.background.withValues(alpha: 0.96),
            p.background.withValues(alpha: 0.6),
            p.background.withValues(alpha: 0),
          ],
          stops: const [0.2, 0.62, 1],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (c.isPlaying || c.cursor > c.selection.start + 0.5)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _NowPill(controller: c, palette: p),
            ),
          Text(crumb,
              style: TextStyle(
                  color: set != null ? p.accent : p.textSub,
                  fontSize: 13,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(fmtPace(st.paceSecPer500),
                      style: numStyle.copyWith(fontSize: 56)),
                  Text('ave. /500m', style: sub),
                ],
              ),
              const SizedBox(width: 18),
              _Small(
                value: st.averageSpm?.round().toString() ?? '--',
                label: 'SR',
                numStyle: numStyle,
                sub: sub,
              ),
              const SizedBox(width: 16),
              _Small(
                value: st.averageDps?.toStringAsFixed(1) ?? '--',
                label: 'DPS m',
                numStyle: numStyle,
                sub: sub,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${fmtDistance(st.distance)} ・ ${fmtDuration(st.duration)}',
            style: sub.copyWith(fontSize: 14),
          ),
        ],
      ),
    );
  }
}

class _Small extends StatelessWidget {
  const _Small({
    required this.value,
    required this.label,
    required this.numStyle,
    required this.sub,
  });

  final String value;
  final String label;
  final TextStyle numStyle;
  final TextStyle sub;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: numStyle.copyWith(fontSize: 28)),
            Text(label, style: sub),
          ],
        ),
      );
}

/// 再生位置の値。再生中か、位置を動かしたときだけ出す(「--」の枠を常に並べない)。
class _NowPill extends StatelessWidget {
  const _NowPill({required this.controller, required this.palette});

  final ReplayController controller;
  final RecordPalette palette;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final tr = controller.track;
    final i = tr.indexAt(controller.cursor);
    final v = tr.isEmpty ? 0.0 : tr.speed[i];
    final moving = v >= replayMovingSpeedMps;
    final working = v >= replayWorkSpeedMps;
    final spm = tr.isEmpty ? null : tr.spm[i];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: p.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.line),
      ),
      child: Text.rich(
        TextSpan(children: [
          TextSpan(
            text: fmtDuration(controller.cursor),
            style: TextStyle(
                color: p.text, fontSize: 16, fontWeight: FontWeight.w800),
          ),
          TextSpan(
            text: moving
                ? '   ${fmtPace(500 / v)}/500m'
                    '${working && spm != null ? '  SR ${spm.round()}' : ''}'
                : '   停止中',
            style: TextStyle(
                color: p.textSub, fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ]),
      ),
    );
  }
}
