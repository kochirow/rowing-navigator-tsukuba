import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/workout_plan.dart';
import 'package:rowing_navigator/services/workout_engine.dart';

void main() {
  test('500m×2 r1:00: 漕ぎ出しで始まり、遅い間は数えず、レストは減って0で次へ', () {
    final engine = WorkoutEngine(const WorkoutPlan(
      workUnit: WorkUnit.distance,
      workValue: 500,
      reps: 2,
      restUnit: RestUnit.time,
      restValue: 60,
    ));
    final t0 = DateTime(2026, 9, 26, 6);
    var s = 0;
    var d = 0.0;
    void fix(double speed) {
      s++;
      d += speed;
      engine.onFix(
          at: t0.add(Duration(seconds: s)),
          speedMetersPerSecond: speed,
          totalDistanceMeters: d);
    }

    fix(0.2); // 基準
    fix(0.2);
    expect(engine.status.phase, WorkoutPhase.ready);
    fix(4); // 漕ぎ出し → 開始
    expect(engine.status.phase, WorkoutPhase.work);
    for (var i = 0; i < 50; i++) {
      fix(4);
    }
    expect(engine.status.remaining, closeTo(300, 0.01));
    fix(1); // 3:00/500m より遅い → 数えない
    expect(engine.status.paused, isTrue);
    expect(engine.status.remaining, closeTo(300, 0.01));
    while (engine.status.phase == WorkoutPhase.work) {
      fix(4);
    }
    expect(engine.status.phase, WorkoutPhase.rest);
    expect(engine.status.restFraction, 1);
    for (var i = 0; i < 30; i++) {
      fix(0.5);
    }
    expect(engine.status.restFraction, closeTo(0.5, 0.02));
    for (var i = 0; i < 30; i++) {
      fix(0.5);
    }
    expect(engine.status.phase, WorkoutPhase.work);
    expect(engine.status.rep, 2);
    while (engine.status.phase == WorkoutPhase.work) {
      fix(4);
    }
    expect(engine.status.phase, WorkoutPhase.done);
  });

  test('30本×2×2セット: 本数で進み、セットの切れ目はセット間レスト', () {
    final engine = WorkoutEngine(const WorkoutPlan(
      workUnit: WorkUnit.strokes,
      workValue: 30,
      reps: 2,
      restUnit: RestUnit.open,
      restValue: 0,
      sets: 2,
      setRestSeconds: 120,
      autoStart: false,
    ));
    for (var i = 0; i < 30; i++) {
      engine.onStroke();
    }
    expect(engine.status.phase, WorkoutPhase.rest, reason: '1本目のあとは本間レスト');
    final t0 = DateTime(2026, 9, 26, 6);
    engine.onFix(at: t0, speedMetersPerSecond: 0.3, totalDistanceMeters: 0);
    engine.onFix(
        at: t0.add(const Duration(seconds: 1)),
        speedMetersPerSecond: 4,
        totalDistanceMeters: 4);
    expect(engine.status.phase, WorkoutPhase.work, reason: 'レスト未定は漕ぎ出しで次へ');
    for (var i = 0; i < 30; i++) {
      engine.onStroke();
    }
    expect(engine.status.phase, WorkoutPhase.setRest, reason: '2本でセット終わり');
    expect(engine.status.rep, 3);
  });
}
