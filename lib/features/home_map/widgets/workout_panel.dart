import 'package:flutter/material.dart';

import '../../../models/workout_plan.dart';
import '../../../services/workout_engine.dart';
import '../../../theme/nav_palette.dart';

/// ワークアウト中に計器の下半分と置き換える表示(少し大きめ)。
///
/// 大きく「いまの区間の残り」、右に何本目か(3/8 rep / レスト中は next)、下に
/// 進み具合の帯(セットの区切りつき)。WORK 中だけ控えめにティール(札・縁・
/// いまの本)。レストは白で、満タンから減っていく帯と数字。0 で次のワーク。
/// 遅くて数えていない間は数字を灰色にし、一時停止の記号だけ出す(読ませない)。
class WorkoutPanel extends StatelessWidget {
  const WorkoutPanel({super.key, required this.plan, required this.status});

  final WorkoutPlan plan;
  final WorkoutStatus status;

  @override
  Widget build(BuildContext context) {
    final phase = status.phase;
    final work = phase == WorkoutPhase.work || phase == WorkoutPhase.ready;
    final resting = phase == WorkoutPhase.rest || phase == WorkoutPhase.setRest;
    final (value, unit) = _valueAndUnit();
    final tag = switch (phase) {
      WorkoutPhase.ready => 'READY',
      WorkoutPhase.work => 'WORK',
      WorkoutPhase.rest || WorkoutPhase.setRest => 'REST',
      WorkoutPhase.done => 'DONE',
    };
    // レスト中の rep は「次に漕ぐ本」(next)。
    final repText = '${status.rep}/${status.totalReps}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              flex: 170,
              child: Container(
                height: 104,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                decoration: BoxDecoration(
                  color: work ? NavPalette.workCell : NavPalette.cell,
                  borderRadius: BorderRadius.circular(14),
                  border: work
                      ? Border.all(
                          color: NavPalette.work.withValues(alpha: 0.55),
                          width: 1.5,
                        )
                      : null,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        _Tag(text: tag, filled: work),
                        if (status.paused) ...[
                          const SizedBox(width: 6),
                          Semantics(
                            label: '遅いので数えていない',
                            child: const Icon(Icons.pause,
                                size: 18, color: NavPalette.label),
                          ),
                        ],
                      ],
                    ),
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.bottomLeft,
                        child: Text(
                          value,
                          maxLines: 1,
                          style: TextStyle(
                            color: status.paused
                                ? NavPalette.valueMuted
                                : NavPalette.value,
                            fontSize: 66,
                            height: 1,
                            fontWeight: FontWeight.bold,
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (status.restFraction != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: status.restFraction!.clamp(0.0, 1.0),
                            minHeight: 8,
                            color: NavPalette.value,
                            backgroundColor: NavPalette.line,
                          ),
                        ),
                      ),
                    Text(
                      unit,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: NavPalette.label,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              flex: 100,
              child: Container(
                height: 104,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                decoration: BoxDecoration(
                  color: NavPalette.cell,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.bottomLeft,
                        child: Text(
                          repText,
                          style: const TextStyle(
                            color: NavPalette.value,
                            fontSize: 44,
                            height: 1,
                            fontWeight: FontWeight.bold,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                    Text(
                      resting ? 'next' : 'rep',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: NavPalette.label,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        _RepBar(plan: plan, status: status),
      ],
    );
  }

  (String, String) _valueAndUnit() {
    final r = status.remaining;
    switch (status.phase) {
      case WorkoutPhase.done:
        return ('完了', '');
      case WorkoutPhase.setRest:
        return (formatWorkoutClock(r.ceil()), 'セット間');
      case WorkoutPhase.rest:
        return switch (plan.restUnit) {
          RestUnit.time => (formatWorkoutClock(r.ceil()), ''),
          RestUnit.strokes => ('${r.ceil()}', 'count'),
          RestUnit.distance => ('${r.ceil()}', 'm'),
          // 未定: 経過を出す(漕ぎ出したら次へ)。
          RestUnit.open => (formatWorkoutClock(r.floor()), '漕ぎ出すと次へ'),
        };
      case WorkoutPhase.ready:
      case WorkoutPhase.work:
        return switch (plan.workUnit) {
          WorkUnit.distance => ('${r.ceil()}', 'm'),
          WorkUnit.time => (formatWorkoutClock(r.ceil()), ''),
          WorkUnit.strokes => ('${r.ceil()}', 'count'),
        };
    }
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.filled});
  final String text;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: filled ? NavPalette.work : null,
        borderRadius: BorderRadius.circular(6),
        border: filled ? null : Border.all(color: NavPalette.value, width: 1.5),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: filled ? const Color(0xFF04221F) : NavPalette.value,
          fontSize: 12,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// 進み具合の帯。終えた本=灰、いまの本=ティール(WORK)/白(REST)、セットの切れ目に隙間。
class _RepBar extends StatelessWidget {
  const _RepBar({required this.plan, required this.status});
  final WorkoutPlan plan;
  final WorkoutStatus status;

  @override
  Widget build(BuildContext context) {
    final resting = status.phase == WorkoutPhase.rest ||
        status.phase == WorkoutPhase.setRest;
    final children = <Widget>[];
    for (var s = 0; s < plan.sets; s++) {
      if (s > 0) children.add(const SizedBox(width: 8));
      for (var r = 0; r < plan.reps; r++) {
        final idx = s * plan.reps + r + 1;
        final done = status.phase == WorkoutPhase.done ||
            idx < status.rep ||
            (resting && idx < status.rep);
        final now = !done && idx == status.rep;
        children.add(Expanded(
          child: Container(
            height: 6,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              color: done
                  ? NavPalette.label
                  : now
                      ? (resting ? NavPalette.value : NavPalette.work)
                      : NavPalette.line,
            ),
          ),
        ));
      }
    }
    return Row(children: children);
  }
}
