import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/hooks/use_workout.dart';
import 'package:rowing_navigator/models/workout_plan.dart';
import 'package:rowing_navigator/services/workout_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _auto = WorkoutPlan(
  workUnit: WorkUnit.distance,
  workValue: 500,
  reps: 8,
  restUnit: RestUnit.time,
  restValue: 120,
);

void main() {
  late UseWorkout workout;
  final navigating = ValueNotifier(false);

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ValueListenableBuilder<bool>(
        valueListenable: navigating,
        builder: (_, value, __) => HookBuilder(
          builder: (_) {
            workout = useWorkout(
              myBoat: null,
              fixProcessedAt: DateTime(2026, 10, 6),
              totalDistanceMeters: 0,
              motion: null,
              navigating: value,
            );
            return const SizedBox();
          },
        ),
      ),
    );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    navigating.value = false;
  });

  testWidgets('航行前に決めたメニューは、航行が始まると READY で始まる', (tester) async {
    await pump(tester);
    workout.prepare(_auto);
    await tester.pump();
    // 航行前はまだ始まらない(計器を置き換えない)。
    expect(workout.prepared, _auto);
    expect(workout.plan, isNull);

    navigating.value = true;
    await tester.pumpAndSettle();
    expect(workout.plan, _auto);
    expect(workout.status!.phase, WorkoutPhase.ready);
    expect(workout.prepared, isNull);
  });

  testWidgets('「漕ぎ出したら始める」でないメニューは自動で始めず、準備されたまま残す', (tester) async {
    // 自動で始めると、桟橋にいるうちに1本目のワークが進んでしまう。
    final manual = _auto.copyWith(autoStart: false);
    await pump(tester);
    workout.prepare(manual);
    navigating.value = true;
    await tester.pumpAndSettle();
    expect(workout.plan, isNull);
    expect(workout.prepared, manual);

    // 航行中にワークアウトのボタンから始めると、準備ぶんは役目を終える。
    workout.start(manual);
    await tester.pump();
    expect(workout.status!.phase, WorkoutPhase.work);
    expect(workout.prepared, isNull);
  });

  testWidgets('航行が終われば、実行中も準備ぶんも次の航行へ持ち越さない', (tester) async {
    await pump(tester);
    workout.prepare(_auto);
    navigating.value = true;
    await tester.pumpAndSettle();
    expect(workout.plan, isNotNull);

    navigating.value = false;
    await tester.pumpAndSettle();
    expect(workout.plan, isNull);
    expect(workout.prepared, isNull);

    // 始めないまま終えた準備ぶんも消える。
    final manual = _auto.copyWith(autoStart: false);
    workout.prepare(manual);
    navigating.value = true;
    await tester.pumpAndSettle();
    navigating.value = false;
    await tester.pumpAndSettle();
    expect(workout.prepared, isNull);

    navigating.value = true;
    await tester.pumpAndSettle();
    expect(workout.plan, isNull);
  });

  testWidgets('取り消した準備ぶんは、航行を始めても始まらない', (tester) async {
    await pump(tester);
    workout.prepare(_auto);
    workout.prepare(null);
    navigating.value = true;
    await tester.pumpAndSettle();
    expect(workout.plan, isNull);
  });
}
