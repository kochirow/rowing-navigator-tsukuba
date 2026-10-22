import 'package:flutter/material.dart';

import '../../../services/record/training_set_detector.dart';
import '../../../theme/record_palette.dart';
import '../replay_controller.dart';
import '../replay_format.dart';

/// 選択区間の名前と範囲・操作。「全体」のときは時間の内訳も出す。
class SelectionCard extends StatelessWidget {
  final ReplayController controller;
  final VoidCallback onShare;
  const SelectionCard(
      {super.key, required this.controller, required this.onShare});

  @override
  Widget build(BuildContext context) {
    final p = RecordPalette.of(context);
    final c = controller;
    final set = c.selectedSet;
    final bout = c.selectedBout;
    final st = c.selectionStats;
    final sel = c.selection;
    final String kind, name, range;
    Color? nameTag;
    String? tag;
    // 眉(kind)は名前で分からないときだけ出す。「セット」+「2セット目」、
    // 「全体」+「この日の練習」は同じことを2回言う。
    if (set != null) {
      kind = '';
      name = '${set.index + 1}セット目';
      tag = set.intensity.label;
      nameTag = p.intensity(set.intensity.index);
      final dirs = {for (final b in set.bouts) c.directionOf(b.range)}
        ..remove(null);
      range = '${fmtDuration(sel.start)} – ${fmtDuration(sel.end)}'
          '${set.intensity == TrainingIntensity.highRate ? ' ・ ${set.bouts.length}本' : ''}'
          '${dirs.isEmpty ? '' : ' ・ ${dirs.length == 1 ? dirs.first : '往復'}'}';
    } else if (bout != null) {
      final parent = c.analysis.sets[bout.setIndex];
      kind = '${parent.index + 1}セット目 ・ ${parent.intensity.label}';
      final dir = c.directionOf(bout.range);
      name =
          '${bout.indexInSet + 1}${parent.intensity.unit}目${dir == null ? '' : ' ・ $dir'}';
      range = '${fmtDuration(sel.start)} – ${fmtDuration(sel.end)}';
    } else if (c.isAll) {
      kind = '';
      name = 'この日の練習';
      range = '${fmtDuration(sel.start)} – ${fmtDuration(sel.end)}';
    } else {
      kind = '選択区間';
      name = '${fmtDuration(sel.start)} – ${fmtDuration(sel.end)}';
      range = '長さ ${fmtDuration(sel.duration)}';
    }
    final String? note;
    if (set != null && set.restSec >= 3) {
      note = set.intensity == TrainingIntensity.highRate
          ? 'レスト ${fmtDuration(set.restSec)} を除いた、${set.bouts.length}本の平均です'
          : 'ターン・停止 ${fmtDuration(set.restSec)} を除いた平均です';
    } else if (st.stoppedSec >= 3) {
      note = 'イージー（停止）${fmtDuration(st.stoppedSec)} を除いた平均です';
    } else {
      note = null;
    }

    return RecordCard(
      palette: p,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (kind.isNotEmpty) ...[
                      Text(kind,
                          style: TextStyle(
                              fontSize: 12,
                              letterSpacing: 1,
                              fontWeight: FontWeight.w800,
                              color: p.textSub)),
                      const SizedBox(height: 3),
                    ],
                    Text.rich(
                        TextSpan(children: [
                          TextSpan(text: name),
                          if (tag != null)
                            TextSpan(
                                text: '  $tag',
                                style: TextStyle(fontSize: 14, color: nameTag)),
                        ]),
                        style: TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                            color: p.text,
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ])),
                    const SizedBox(height: 2),
                    Text(range,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: p.textSub)),
                  ]),
            ),
            _Pill(label: '絞る', palette: p, onTap: c.zoomTimelineToSelection),
            const SizedBox(width: 6),
            _Pill(label: '共有', palette: p, accent: true, onTap: onShare),
          ]),
          // 4つの数字(/500m・SR・DPS・距離と時間)は、地図の下端の「答え」
          // (AnswerOverlay)が同じ選択区間について大きく出している。
          // ここで繰り返さず、名前・範囲・操作と、平均の注記だけにする。
          if (note != null) ...[
            const SizedBox(height: 10),
            Text(note, style: TextStyle(fontSize: 12, color: p.textSub)),
          ],
          if (c.isAll) _Overview(controller: c, palette: p),
        ],
      ),
    );
  }
}

class _Overview extends StatelessWidget {
  final ReplayController controller;
  final RecordPalette palette;
  const _Overview({required this.controller, required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final o = controller.analysis.overview;
    final total = o.practiceSec + o.stoppedSec;
    final parts = [
      ('UT', o.rowingByIntensity[TrainingIntensity.ut]!, p.metricPace),
      ('AT', o.rowingByIntensity[TrainingIntensity.at]!, p.metricSpm),
      ('ハイレート', o.rowingByIntensity[TrainingIntensity.highRate]!, p.cursor),
      ('パドル・アップ等', o.otherMovingSec, p.textMute),
      ('停止', o.stoppedSec, p.surfaceHigher),
    ];
    TextStyle big(Color c) => TextStyle(
        fontSize: 26,
        fontWeight: FontWeight.w800,
        color: c,
        fontFeatures: const [FontFeature.tabularFigures()]);
    TextStyle eyebrow() => TextStyle(
        fontSize: 12,
        letterSpacing: 1,
        fontWeight: FontWeight.w800,
        color: p.textSub);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('ワーク時間', style: eyebrow()),
              Text(fmtDuration(o.rowingSec), style: big(p.text)),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('練習時間', style: eyebrow()),
            Text(fmtDuration(o.practiceSec), style: big(p.textSub)),
          ]),
        ]),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 12,
            child: Row(children: [
              for (final part in parts)
                if (part.$2 > 0 && total > 0)
                  Expanded(
                    flex: (part.$2 / total * 1000).round().clamp(1, 1000),
                    child: ColoredBox(color: part.$3),
                  ),
            ]),
          ),
        ),
        const SizedBox(height: 6),
        for (var k = 0; k < parts.length; k++)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              border: k == 3 ? Border(top: BorderSide(color: p.line)) : null,
            ),
            child: Row(children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                    color: parts[k].$3, borderRadius: BorderRadius.circular(3)),
              ),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(parts[k].$1,
                      style: TextStyle(fontSize: 13, color: p.text))),
              Text(fmtDuration(parts[k].$2),
                  style: TextStyle(
                      fontSize: 13,
                      color: p.text,
                      fontFeatures: const [FontFeature.tabularFigures()])),
              SizedBox(
                width: 44,
                child: Text(
                    total > 0 ? '${(parts[k].$2 / total * 100).round()}%' : '',
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 12, color: p.textMute)),
              ),
            ]),
          ),
        Text(
          'ワーク時間 = 各セットの本・区間の合計（練習の強度で漕いだ時間）。'
          '練習時間 = 艇が動いていた時間の合計（パドル・アップを含む）。'
          '記録の長さ ${fmtDuration(o.recordSec)}。',
          style: TextStyle(fontSize: 12, height: 1.5, color: p.textSub),
        ),
      ]),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final RecordPalette palette;
  final bool accent;
  final VoidCallback onTap;
  const _Pill(
      {required this.label,
      required this.palette,
      required this.onTap,
      this.accent = false});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Material(
      color: accent ? p.accent : p.surfaceHigh,
      shape: StadiumBorder(side: BorderSide(color: accent ? p.accent : p.line)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40, minWidth: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Center(
              child: Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: accent ? p.onAccent : p.text)),
            ),
          ),
        ),
      ),
    );
  }
}

/// 記録画面で共通に使うカード。
class RecordCard extends StatelessWidget {
  final RecordPalette palette;
  final Widget child;
  final EdgeInsets padding;
  const RecordCard({
    super.key,
    required this.palette,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      child: Material(
        color: palette.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: palette.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}
