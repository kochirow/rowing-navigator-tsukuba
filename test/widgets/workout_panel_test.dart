import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/features/home_map/widgets/workout_panel.dart';
import 'package:rowing_navigator/models/workout_plan.dart';
import 'package:rowing_navigator/services/workout_engine.dart';

const _plan = WorkoutPlan(
  workUnit: WorkUnit.distance,
  workValue: 500,
  reps: 8,
  restUnit: RestUnit.time,
  restValue: 120,
);

void main() {
  Future<void> pump(WidgetTester tester, Widget panel) => tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SizedBox(width: 360, child: panel))),
      );

  testWidgets('待機は1本目の目標と ▶ を出し、面を押すと始まる。右下は ×', (tester) async {
    var started = 0, dismissed = 0;
    await pump(
      tester,
      WorkoutPanel(
        plan: _plan,
        status: null,
        onStart: () => started++,
        onStop: () => fail('待機中に ■ は出ない'),
        onDismiss: () => dismissed++,
      ),
    );
    expect(find.text('500'), findsOneWidget);
    expect(find.text('1/8'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.text('WORK'), findsNothing);
    expect(find.byKey(const ValueKey('workout-stop')), findsNothing);

    await tester.tap(find.text('500'));
    expect(started, 1);
    await tester.tap(find.byKey(const ValueKey('workout-dismiss')));
    expect(dismissed, 1);
  });

  testWidgets('READY は ▶ を出し、WORK は ▶ を出さず右下に ■', (tester) async {
    var started = 0, stopped = 0;
    final engine = WorkoutEngine(_plan);
    Widget panel() => WorkoutPanel(
          plan: _plan,
          status: engine.status,
          onStart: () => started++,
          onStop: () => stopped++,
          onDismiss: () => fail('実行中に × は出ない'),
        );
    await pump(tester, panel());
    expect(find.text('READY'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('workout-main-cell')));
    expect(started, 1);

    engine.startNow();
    await pump(tester, panel());
    expect(find.text('WORK'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    await tester.tap(find.byKey(const ValueKey('workout-main-cell')));
    expect(started, 1, reason: 'WORK 中に面を押しても何も起きない');
    await tester.tap(find.byKey(const ValueKey('workout-stop')));
    expect(stopped, 1);
  });
}
