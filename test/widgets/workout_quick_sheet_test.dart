import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/features/home_map/widgets/workout_quick_sheet.dart';
import 'package:rowing_navigator/hooks/use_workout.dart';
import 'package:rowing_navigator/models/workout_plan.dart';
import 'package:rowing_navigator/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _plan = WorkoutPlan(
  workUnit: WorkUnit.distance,
  workValue: 500,
  reps: 8,
  restUnit: RestUnit.time,
  restValue: 120,
  autoStart: false,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpHost(
    WidgetTester tester,
    void Function(BuildContext context) onOpen,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => onOpen(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('出艇前のメニューから設定画面へ入り、決めたメニューを準備へ渡す', (tester) async {
    final preparedCalls = <WorkoutPlan?>[];
    var started = 0;
    final workout = UseWorkout(
      plan: null,
      status: null,
      start: (_) => started++,
      stop: () {},
      prepared: null,
      prepare: preparedCalls.add,
    );
    await pumpHost(
      tester,
      (context) => workoutPrepareMenuAction(context, workout).onTap(),
    );
    expect(find.text('次の航行で使う'), findsOneWidget);

    await tester.tap(find.text('次の航行で使う'));
    await tester.pumpAndSettle();
    expect(preparedCalls, hasLength(1));
    expect(preparedCalls.single, isNotNull);
    // 航行前には始めない。
    expect(started, 0);
    expect(find.textContaining('次の航行で使うメニュー'), findsOneWidget);
  });

  testWidgets('決めてあるメニューは、メニューの項目に内容を出す', (tester) async {
    final workout = UseWorkout(
      plan: null,
      status: null,
      start: (_) {},
      stop: () {},
      prepared: _plan,
      prepare: (_) {},
    );
    late MapEntry<String, String?> shown;
    await pumpHost(tester, (context) {
      final action = workoutPrepareMenuAction(context, workout);
      shown = MapEntry(action.title, action.subtitle);
    });
    expect(shown.key, 'ワークアウト');
    expect(shown.value, '次の航行で使う: 500m×8');
  });

  testWidgets('航行中のシートは、準備したメニューを先頭に出して1回で始められる', (tester) async {
    WorkoutPlan? started;
    await pumpHost(
      tester,
      (context) => showWorkoutQuickSheet(
        context,
        running: null,
        prepared: _plan,
        onStart: (plan) => started = plan,
        onStop: () {},
      ),
    );
    expect(find.text('準備したメニュー'), findsOneWidget);
    expect(find.text('500m×8 ・ r2:00'), findsOneWidget);

    await tester.tap(find.text('始める'));
    await tester.pumpAndSettle();
    expect(started, _plan);
    expect(find.text('準備したメニュー'), findsNothing);
  });

  testWidgets('実行中は、準備したメニューの行を出さない', (tester) async {
    await pumpHost(
      tester,
      (context) => showWorkoutQuickSheet(
        context,
        running: _plan,
        prepared: _plan,
        onStart: (_) {},
        onStop: () {},
      ),
    );
    expect(find.text('実行中'), findsOneWidget);
    expect(find.text('準備したメニュー'), findsNothing);
  });
}
