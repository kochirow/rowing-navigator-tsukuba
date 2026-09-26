import 'package:flutter/material.dart';

import '../../../services/record/training_set_detector.dart';
import '../../../theme/record_palette.dart';
import '../replay_controller.dart';
import '../replay_format.dart';

/// 選択区間の名前と4つの数字。「全体」のときは時間の内訳も出す。
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
    if (set != null) {
      kind = 'セット';
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
      kind = '全体';
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
                    Text(kind,
                        style: TextStyle(
                            fontSize: 12,
                            letterSpacing: 1,
                            fontWeight: FontWeight.w800,
                            color: p.textSub)),
                    const SizedBox(height: 3),
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
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
                child: _Tile(
                    palette: p,
                    color: p.metricPace,
                    label: '平均 /500m',
                    value: fmtPace(st.paceSecPer500))),
            const SizedBox(width: 10),
            Expanded(
                child: _Tile(
                    palette: p,
                    color: p.metricSpm,
                    label: '平均SR',
                    value: st.averageSpm == null
                        ? '--'
                        : '${st.averageSpm!.round()}',
                    unit: 'spm')),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
                child: _Tile(
                    palette: p,
                    color: p.metricDps,
                    label: '平均DPS',
                    value: st.averageDps == null
                        ? '--'
                        : st.averageDps!.toStringAsFixed(1),
                    unit: 'm')),
            const SizedBox(width: 10),
            Expanded(
                child: _Tile(
                    palette: p,
                    color: p.textSub,
                    label: '距離 ・ 時間',
                    value: st.distance >= 1000
                        ? (st.distance / 1000).toStringAsFixed(2)
                        : '${st.distance.round()}',
                    unit: st.distance >= 1000 ? 'km' : 'm',
                    sub: fmtDuration(set?.range.duration ?? st.duration))),
          ]),
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

class _Tile extends StatelessWidget {
  final RecordPalette palette;
  final Color color;
  final String label;
  final String value;
  final String? unit;
  final String? sub;

  const _Tile({
    required this.palette,
    required this.color,
    required this.label,
    required this.value,
    this.unit,
    this.sub,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 11, 10, 10),
      decoration: BoxDecoration(
        color: p.surfaceHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(children: [
        Container(width: 3, height: 44, color: color),
        const SizedBox(width: 8),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: p.textSub)),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: value),
                  if (unit != null)
                    TextSpan(
                        text: ' $unit',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: p.textSub)),
                ]),
                style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    color: p.text,
                    fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ),
            if (sub != null)
              Text(sub!,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: p.textSub)),
          ]),
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
