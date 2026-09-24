import 'package:flutter/material.dart';

import '../../../services/record/replay_track.dart';
import '../../../theme/record_palette.dart';
import '../replay_controller.dart';
import '../replay_format.dart';
import 'selection_card.dart';

/// グラフの下に畳んでおく欄（内訳・区間の微調整・250mラップ）。既定は閉じる。
///
/// 使う場面が少ないので、グラフへ最短で届くことを優先して1枚にまとめ、文字も小さめにする
/// （実装計画 §1.1）。
class DetailSections extends StatelessWidget {
  final ReplayController controller;
  const DetailSections({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final p = RecordPalette.of(context);
    final c = controller;
    final set = c.selectedSet ??
        (c.selectedBout == null
            ? null
            : c.analysis.sets[c.selectedBout!.setIndex]);
    final showBreakdown = set != null && set.bouts.length > 1;
    return RecordCard(
      palette: p,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Column(children: [
        if (showBreakdown)
          _Fold(
            palette: p,
            title: '内訳（各本・区間）',
            trailing:
                '${set.index + 1}セット目 ・ ${set.bouts.length}${set.intensity.unit}',
            child: _Breakdown(controller: c),
          ),
        _Fold(
          palette: p,
          title: '区間を細かく調整',
          trailing:
              '${fmtDuration(c.selection.start)} – ${fmtDuration(c.selection.end)}',
          divider: showBreakdown,
          child: _FineAdjust(controller: c),
        ),
        _Fold(
          palette: p,
          title: '250mラップ',
          divider: true,
          child: _Laps(controller: c),
        ),
      ]),
    );
  }
}

class _Fold extends StatelessWidget {
  final RecordPalette palette;
  final String title;
  final String? trailing;
  final bool divider;
  final Widget child;

  const _Fold({
    required this.palette,
    required this.title,
    required this.child,
    this.trailing,
    this.divider = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: divider ? Border(top: BorderSide(color: p.line)) : null,
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 12),
          iconColor: p.textSub,
          collapsedIconColor: p.textSub,
          title: Row(children: [
            Expanded(
              child: Text(title,
                  style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w800,
                      color: p.textSub)),
            ),
            if (trailing != null)
              Text(trailing!,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: p.textMute,
                      fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
          children: [child],
        ),
      ),
    );
  }
}

TextStyle _cell(RecordPalette p, {bool strong = false}) => TextStyle(
      fontSize: 12,
      fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
      color: strong ? p.text : p.textSub,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

class _Breakdown extends StatelessWidget {
  final ReplayController controller;
  const _Breakdown({required this.controller});

  @override
  Widget build(BuildContext context) {
    final p = RecordPalette.of(context);
    final c = controller;
    final set = c.selectedSet ?? c.analysis.sets[c.selectedBout!.setIndex];
    final unit = set.intensity.unit;
    final head =
        TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: p.textMute);
    Widget line(List<Widget> cells, {VoidCallback? onTap, bool on = false}) =>
        InkWell(
          onTap: onTap,
          child: Container(
            color: on ? p.surfaceHigh : null,
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
            child: Row(children: [
              for (var k = 0; k < cells.length; k++)
                Expanded(flex: const [8, 6, 6, 7, 4, 9][k], child: cells[k]),
            ]),
          ),
        );
    Widget r(String s, TextStyle st) =>
        Text(s, textAlign: TextAlign.right, style: st);
    return Column(children: [
      line([
        Text(unit, style: head),
        r('時間', head),
        r('距離', head),
        r('平均 /500m', head),
        r('SR', head),
        r(set.intensity.unit == '本' ? 'レスト' : '間', head),
      ]),
      for (var j = 0; j < set.bouts.length; j++)
        Builder(builder: (context) {
          final b = set.bouts[j];
          final next = j + 1 < set.bouts.length ? set.bouts[j + 1] : null;
          final gap =
              next == null ? null : ReplayRange(b.range.end, next.range.start);
          return line(
            [
              Text(
                  '${j + 1}$unit目${c.directionOf(b.range) == null ? '' : ' ${c.directionOf(b.range)}'}',
                  style: _cell(p)),
              r(fmtDuration(b.range.duration), _cell(p)),
              r('${b.stats.distance.round()}m', _cell(p)),
              r(fmtPace(b.stats.paceSecPer500), _cell(p, strong: true)),
              r('${b.stats.averageSpm?.round() ?? '--'}', _cell(p)),
              r(
                  gap == null
                      ? ''
                      : '${fmtDuration(gap.duration)} ${c.analysis.gapKind(gap).label}\n'
                          '${(c.track.distanceAt(gap.end) - c.track.distanceAt(gap.start)).round()}m',
                  _cell(p).copyWith(fontSize: 10.5, color: p.textMute)),
            ],
            on: identical(c.selectedBout, b),
            onTap: () => c.selectBout(b),
          );
        }),
    ]);
  }
}

class _FineAdjust extends StatefulWidget {
  final ReplayController controller;
  const _FineAdjust({required this.controller});

  @override
  State<_FineAdjust> createState() => _FineAdjustState();
}

class _FineAdjustState extends State<_FineAdjust> {
  final _from = TextEditingController();
  final _to = TextEditingController();
  final _fromFocus = FocusNode();
  final _toFocus = FocusNode();
  String? _error;

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    _fromFocus.dispose();
    _toFocus.dispose();
    super.dispose();
  }

  static double? _parse(String s) {
    final m = RegExp(r'^\s*(?:(\d+):)?(\d{1,3}):([0-5]\d)\s*$').firstMatch(s);
    if (m == null) return null;
    return (int.parse(m.group(1) ?? '0') * 3600 +
            int.parse(m.group(2)!) * 60 +
            int.parse(m.group(3)!))
        .toDouble();
  }

  void _apply() {
    final c = widget.controller;
    final a = _parse(_from.text), b = _parse(_to.text);
    setState(() {
      if (a == null || b == null) {
        _error = '「分:秒」で入力してください（例 12:30）';
      } else if (b <= a) {
        _error = '終了は開始より後にしてください';
      } else if (b > c.duration + 1) {
        _error = 'この記録は ${fmtDuration(c.duration)} までです';
      } else {
        _error = null;
        FocusScope.of(context).unfocus();
        c.select(ReplayRange(a, b));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = RecordPalette.of(context);
    final c = widget.controller;
    // 入力中は書き換えない。それ以外は選択区間に合わせる。
    if (!_fromFocus.hasFocus) _from.text = fmtDuration(c.selection.start);
    if (!_toFocus.hasFocus) _to.text = fmtDuration(c.selection.end);
    Widget nudges(bool start) => Row(children: [
          SizedBox(
            width: 34,
            child: Text(start ? '開始' : '終了',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: p.textSub)),
          ),
          Expanded(
            child: Text(
                fmtDuration(start ? c.selection.start : c.selection.end),
                style: _cell(p, strong: true).copyWith(fontSize: 16)),
          ),
          for (final d in const [-30.0, -1.0, 1.0, 30.0]) ...[
            if (d == 1) const SizedBox(width: 6),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: _SmallButton(
                label: '${d > 0 ? '+' : '−'}${d.abs().round()}秒',
                palette: p,
                onTap: () => c.nudge(start: start, seconds: d),
              ),
            ),
          ],
        ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('ふだんは時間軸のつまみで選べます。ここでは秒単位で合わせたり、時刻を入力したりできます。',
          style: TextStyle(fontSize: 11.5, height: 1.5, color: p.textSub)),
      const SizedBox(height: 8),
      nudges(true),
      const SizedBox(height: 6),
      nudges(false),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
            child: _SmallButton(
                label: '再生位置を開始にする', palette: p, onTap: c.setStartAtCursor)),
        const SizedBox(width: 8),
        Expanded(
            child: _SmallButton(
                label: '再生位置を終了にする', palette: p, onTap: c.setEndAtCursor)),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
            child: _TimeField(
                controller: _from,
                focusNode: _fromFocus,
                palette: p,
                label: '開始（分:秒）')),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text('–', style: TextStyle(color: p.textSub)),
        ),
        Expanded(
            child: _TimeField(
                controller: _to,
                focusNode: _toFocus,
                palette: p,
                label: '終了（分:秒）')),
        const SizedBox(width: 8),
        _SmallButton(label: '時間で指定', palette: p, onTap: _apply),
      ]),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(_error!,
              style: const TextStyle(fontSize: 12, color: Color(0xFFFF7A7A))),
        ),
    ]);
  }
}

class _TimeField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final RecordPalette palette;
  final String label;
  const _TimeField({
    required this.controller,
    required this.focusNode,
    required this.palette,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return TextField(
      controller: controller,
      focusNode: focusNode,
      keyboardType: TextInputType.datetime,
      textAlign: TextAlign.center,
      style: _cell(p, strong: true).copyWith(fontSize: 14),
      decoration: InputDecoration(
        isDense: true,
        semanticCounterText: label,
        filled: true,
        fillColor: p.surfaceHigh,
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: p.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: p.line),
        ),
      ),
    );
  }
}

class _SmallButton extends StatelessWidget {
  final String label;
  final RecordPalette palette;
  final VoidCallback onTap;
  const _SmallButton(
      {required this.label, required this.palette, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Material(
      color: p.surfaceHigher,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9),
            child: Center(
              child: Text(label,
                  maxLines: 1,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: p.text)),
            ),
          ),
        ),
      ),
    );
  }
}

class _Laps extends StatelessWidget {
  final ReplayController controller;
  const _Laps({required this.controller});

  @override
  Widget build(BuildContext context) {
    final p = RecordPalette.of(context);
    final laps = controller.analysis.analyzer.laps(controller.selection);
    if (laps.isEmpty) {
      return Text('250mに満たない区間です',
          style: TextStyle(fontSize: 12, color: p.textSub));
    }
    final full =
        laps.where((l) => !l.isPartial && l.stats.paceSecPer500 != null);
    final avg = full.isEmpty
        ? null
        : full.map((l) => l.stats.paceSecPer500!).reduce((a, b) => a + b) /
            full.length;
    final head =
        TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: p.textMute);
    Widget line(List<Widget> cells) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            for (var k = 0; k < cells.length; k++)
              Expanded(flex: const [10, 6, 7, 4, 5, 6][k], child: cells[k]),
          ]),
        );
    Widget r(String s, TextStyle st) =>
        Text(s, textAlign: TextAlign.right, style: st);
    return Column(children: [
      line([
        Text('区間', style: head),
        r('ラップ', head),
        r('/500m', head),
        r('SR', head),
        r('DPS', head),
        r('平均差', head),
      ]),
      for (final l in laps)
        Builder(builder: (context) {
          final pace = l.stats.paceSecPer500;
          final diff =
              avg != null && pace != null && !l.isPartial ? pace - avg : null;
          return line([
            Text(
                '${l.fromMeters.round()}–${l.toMeters.round()}${l.isPartial ? ' 端数' : ''}',
                style: _cell(p)),
            r(fmtDuration(l.range.duration), _cell(p)),
            r(fmtPace(pace), _cell(p, strong: true)),
            r('${l.stats.averageSpm?.round() ?? '--'}', _cell(p)),
            r(l.stats.averageDps?.toStringAsFixed(1) ?? '--', _cell(p)),
            r(
                diff == null
                    ? ''
                    : '${diff > 0 ? '+' : ''}${diff.toStringAsFixed(1)}',
                _cell(p).copyWith(
                    color: diff == null
                        ? p.textSub
                        : diff > 0
                            ? const Color(0xFFFF8F7A)
                            : p.accent)),
          ]);
        }),
    ]);
  }
}

/// タイムの推定に使った記録（艇速の手がかりの採否）。
class FusionReportCard extends StatelessWidget {
  final ReplayController controller;
  const FusionReportCard({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final p = RecordPalette.of(context);
    final scores = controller.analysis.estimated.scores;
    return RecordCard(
      palette: p,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: _Fold(
        palette: p,
        title: 'タイムの推定に使った記録',
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
            '艇速の手がかりを並べ、この記録でほかの手がかりと食い違いが大きいものを外しています。'
            'アプリが記録した値も、よく一致していれば使います。',
            style: TextStyle(fontSize: 11.5, height: 1.5, color: p.textSub),
          ),
          const SizedBox(height: 6),
          for (final s in scores)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Expanded(child: Text(s.candidate.label, style: _cell(p))),
                SizedBox(
                  width: 90,
                  child: Text(
                      s.deviation == null
                          ? 'データ不足'
                          : 'ずれ ${(s.deviation! * 100).toStringAsFixed(1)}%',
                      textAlign: TextAlign.right,
                      style: _cell(p)),
                ),
                SizedBox(
                  width: 72,
                  child: Text(s.adopted ? '使う' : '使わない',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: s.adopted ? p.accent : p.textMute)),
                ),
              ]),
            ),
        ]),
      ),
    );
  }
}
