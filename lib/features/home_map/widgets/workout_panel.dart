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
///
/// 操作(2026-10-23)。説明の文言は置かず、記号と位置で伝える:
/// - [status] が null = 待機(準備したメニューを、まだ始めていない)。1本目の
///   目標を灰色で見せ、左の面に ▶ を出す。面のどこを押しても始まる。
///   READY も同じく ▶(漕ぎ出しを待たずに始める)。
/// - 右下(ドラムの RESET と同じ場所)に、実行中は ■(止める)、待機中は ×
///   (下半分を元の計器へ戻す)。■ で止めると待機へ戻るので、▶ でやり直せる。
///
/// 計器そのもの(数字)をタップで操作する案は採らなかった。数字の面は
/// ドラムでは「回す」ものなので、同じ場所が押すと別のことをするのは
/// 見た目から分からない。押せる面には必ず ▶ が付く。
class WorkoutPanel extends StatelessWidget {
  const WorkoutPanel({
    super.key,
    required this.plan,
    required this.status,
    this.onStart,
    this.onStop,
    this.onDismiss,
  });

  final WorkoutPlan plan;

  /// null なら待機中。
  final WorkoutStatus? status;
  final VoidCallback? onStart;
  final VoidCallback? onStop;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final standby = this.status == null;
    // 待機中は「始めたらこうなる」1本目を見せる。
    final status =
        this.status ?? WorkoutEngine(plan, waitForRowing: false).status;
    final phase = status.phase;
    final work =
        !standby && (phase == WorkoutPhase.work || phase == WorkoutPhase.ready);
    final resting = phase == WorkoutPhase.rest || phase == WorkoutPhase.setRest;
    final start = (standby || phase == WorkoutPhase.ready) ? onStart : null;
    final (value, unit) = _valueAndUnit(status);
    final tag = standby
        ? null
        : switch (phase) {
            WorkoutPhase.ready => 'READY',
            WorkoutPhase.work => 'WORK',
            WorkoutPhase.rest || WorkoutPhase.setRest => 'REST',
            WorkoutPhase.done => 'DONE',
          };
    final corner = standby ? onDismiss : onStop;
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
              child: Semantics(
                button: start != null,
                label: start != null ? 'ワークアウトを始める' : null,
                child: Material(
                  color: work ? NavPalette.workCell : NavPalette.cell,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: work
                        ? BorderSide(
                            color: NavPalette.work.withValues(alpha: 0.55),
                            width: 1.5,
                          )
                        : BorderSide.none,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    key: const ValueKey('workout-main-cell'),
                    onTap: start,
                    child: Container(
                      height: 104,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: _MainValue(
                              tag: tag,
                              work: work,
                              paused: status.paused,
                              muted: standby || status.paused,
                              value: value,
                              unit: unit,
                              restFraction: status.restFraction,
                            ),
                          ),
                          if (start != null) ...[
                            const SizedBox(width: 8),
                            const _PlayMark(),
                          ],
                        ],
                      ),
                    ),
                  ),
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
                          style: TextStyle(
                            color: standby
                                ? NavPalette.valueMuted
                                : NavPalette.value,
                            fontSize: 44,
                            height: 1,
                            fontWeight: FontWeight.bold,
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
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
        _RepBar(plan: plan, status: status, standby: standby),
        if (corner != null)
          Align(
            alignment: Alignment.centerRight,
            child: _CornerButton(
              key: ValueKey(standby ? 'workout-dismiss' : 'workout-stop'),
              icon: standby ? Icons.close : Icons.stop_rounded,
              semanticsLabel: standby ? 'ワークアウトを外す' : 'ワークアウトを止める',
              onPressed: corner,
            ),
          ),
      ],
    );
  }

  (String, String) _valueAndUnit(WorkoutStatus status) {
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

/// 左の面の中身(札・大きな数字・レストの帯・単位)。
class _MainValue extends StatelessWidget {
  const _MainValue({
    required this.tag,
    required this.work,
    required this.paused,
    required this.muted,
    required this.value,
    required this.unit,
    required this.restFraction,
  });

  final String? tag;
  final bool work;
  final bool paused;
  final bool muted;
  final String value;
  final String unit;
  final double? restFraction;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (tag != null) _Tag(text: tag!, filled: work),
            if (paused) ...[
              const SizedBox(width: 6),
              Semantics(
                label: '遅いので数えていない',
                child:
                    const Icon(Icons.pause, size: 18, color: NavPalette.label),
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
                color: muted ? NavPalette.valueMuted : NavPalette.value,
                fontSize: 66,
                height: 1,
                fontWeight: FontWeight.bold,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        if (restFraction != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: restFraction!.clamp(0.0, 1.0),
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
    );
  }
}

/// 押せば始まる、の印。ティールの丸に ▶。押すのは面全体。
class _PlayMark extends StatelessWidget {
  const _PlayMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      decoration: const BoxDecoration(
        color: NavPalette.work,
        shape: BoxShape.circle,
      ),
      child: const Icon(
        Icons.play_arrow_rounded,
        size: 40,
        color: Color(0xFF04221F),
      ),
    );
  }
}

/// 右下の ■ / ×。ドラムの RESET と同じ位置・同じ控えめさ
/// (押すのは止まっているとき。数字の邪魔をしない)。
class _CornerButton extends StatelessWidget {
  const _CornerButton({
    super.key,
    required this.icon,
    required this.semanticsLabel,
    required this.onPressed,
  });

  final IconData icon;
  final String semanticsLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticsLabel,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          width: 56,
          height: 36,
          child: Icon(icon, size: 28, color: NavPalette.label),
        ),
      ),
    );
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
/// 待機中は「いまの本」を持たない。
class _RepBar extends StatelessWidget {
  const _RepBar({
    required this.plan,
    required this.status,
    required this.standby,
  });
  final WorkoutPlan plan;
  final WorkoutStatus status;
  final bool standby;

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
        final now = !standby && !done && idx == status.rep;
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
