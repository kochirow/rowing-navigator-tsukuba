import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rowing_navigator/features/home_map/widgets/nav_setting_modal.dart';
import 'package:rowing_navigator/models/workout_plan.dart';
import 'package:rowing_navigator/theme/app_theme.dart';
import 'package:rowing_navigator/types/boat_type.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _plan = WorkoutPlan(
  workUnit: WorkUnit.distance,
  workValue: 1000,
  reps: 4,
  restUnit: RestUnit.time,
  restValue: 180,
);

void main() {
  Future<void> pump(
    WidgetTester tester, {
    WorkoutPlan? prepared,
    void Function(WorkoutPlan?)? onWorkoutChanged,
    Future<void> Function()? onStart,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: NavSettingModal(
              preparedWorkout: prepared,
              onWorkoutChanged: onWorkoutChanged,
              onPressStartNav: (_, __, ___) async => onStart?.call(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  String summary(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('nav-setting-workout-summary')))
      .data!;

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('航行開始の設定から、この航行で使うワークアウトを決められる', (tester) async {
    final changes = <WorkoutPlan?>[];
    await pump(tester, onWorkoutChanged: changes.add);
    expect(summary(tester), '決めていません(フリー)');

    await tester.tap(find.text('ワークアウト'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('次の航行で使う'));
    await tester.pumpAndSettle();

    expect(changes, hasLength(1));
    expect(changes.single, isNotNull);
    // 設定画面から戻ったシートに、決めた内容が出る。
    expect(summary(tester), '500m×8 ・ r2:00');
    expect(find.textContaining('漕ぎ出しで1本目'), findsOneWidget);
  });

  testWidgets('決めてあるワークアウトを出し、その場でやめられる', (tester) async {
    final changes = <WorkoutPlan?>[];
    await pump(tester, prepared: _plan, onWorkoutChanged: changes.add);
    expect(summary(tester), '1000m×4 ・ r3:00');

    await tester.tap(find.text('やめる'));
    await tester.pump();
    expect(changes, [null]);
    expect(summary(tester), '決めていません(フリー)');
  });

  testWidgets('ワークアウトの欄は、前回設定の近道の「航行スタート」より上にある', (tester) async {
    SharedPreferences.setMockInitialValues({
      'navigation_display_name_v1': '後藤',
      'navigation_boat_type_v1': BoatType.r_1x.name,
      'navigation_seat_position_v1': 1,
    });
    await pump(tester, prepared: _plan, onWorkoutChanged: (_) {});
    final workoutY = tester
        .getTopLeft(find.byKey(const ValueKey('nav-setting-workout-summary')))
        .dy;
    final startY = tester.getTopLeft(find.text('この設定で航行スタート')).dy;
    expect(workoutY, lessThan(startY));
  });

  testWidgets('ワークアウトを決めなくても航行は始められる', (tester) async {
    var started = 0;
    SharedPreferences.setMockInitialValues({
      'navigation_display_name_v1': '後藤',
      'navigation_boat_type_v1': BoatType.r_1x.name,
      'navigation_seat_position_v1': 1,
    });
    await pump(
      tester,
      onWorkoutChanged: (_) {},
      onStart: () async => started++,
    );
    await tester.tap(find.text('この設定で航行スタート'));
    await tester.pumpAndSettle();
    expect(started, 1);
  });
}
