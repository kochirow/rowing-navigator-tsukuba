import 'package:flutter/material.dart';

import '../../../services/record/training_set_detector.dart';
import '../../../theme/record_palette.dart';
import '../replay_controller.dart';
import '../replay_format.dart';

/// セットのカードの横並び（先頭は「全体」）。
class SetCards extends StatelessWidget {
  final ReplayController controller;
  const SetCards({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final p = RecordPalette.of(context);
    final sets = controller.analysis.sets;
    final selected = controller.selectedSet ??
        (controller.selectedBout == null
            ? null
            : sets[controller.selectedBout!.setIndex]);
    return SizedBox(
      height: 116,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 2),
        itemCount: sets.length + 1,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, k) {
          if (k == 0) {
            return _Card(
              palette: p,
              selected: controller.isAll,
              width: 74,
              onTap: controller.selectAll,
              child: Center(
                child: Text('全体',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: p.text)),
              ),
            );
          }
          final s = sets[k - 1];
          final st = s.stats;
          final ratio = st.paceSecPer500 == null
              ? 0.0
              : controller.analysis.paceRatio(st.paceSecPer500!);
          final head = s.intensity == TrainingIntensity.highRate
              ? '${s.bouts.length}本 ・ ${fmtDistance(st.distance)}'
              : '${fmtDuration(s.rowingSec)} ・ ${fmtDistance(st.distance)}';
          return _Card(
            palette: p,
            selected: identical(selected, s),
            width: 124,
            onTap: () => controller.selectSet(s),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text('${s.index + 1}セット目',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: p.textSub)),
                  ),
                  Text(s.intensity.label,
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: p.intensity(s.intensity.index))),
                ]),
                const SizedBox(height: 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text('ave.',
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: p.textMute)),
                      const SizedBox(width: 4),
                      Text(fmtPace(st.paceSecPer500),
                          style: TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w800,
                              color: p.text,
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ])),
                    ],
                  ),
                ),
                Text('$head\nSR${st.averageSpm?.round() ?? '--'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 10.5,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                        color: p.textSub)),
                const Spacer(),
                Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: RecordPalette.paceRamp(ratio),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final RecordPalette palette;
  final bool selected;
  final double width;
  final VoidCallback onTap;
  final Widget child;

  const _Card({
    required this.palette,
    required this.selected,
    required this.width,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? palette.surfaceHigh : palette.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
            color: selected ? palette.accent : palette.line,
            width: selected ? 2 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: SizedBox(
          width: width,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(11, 10, 11, 10),
            child: child,
          ),
        ),
      ),
    );
  }
}
