import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/workout_plan.dart';
import 'package:rowing_navigator/screens/workout_setup_screen.dart';
import 'package:rowing_navigator/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _plan = WorkoutPlan(
  workUnit: WorkUnit.distance,
  workValue: 1000,
  reps: 4,
  restUnit: RestUnit.time,
  restValue: 180,
);

Future<void> _pump(
  WidgetTester tester, {
  required ThemeData theme,
  Size size = const Size(390, 844),
  ValueChanged<WorkoutPlan?>? onResult,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                final plan = await Navigator.of(context).push<WorkoutPlan>(
                  MaterialPageRoute(builder: (_) => const WorkoutSetupScreen()),
                );
                onResult?.call(plan);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'workout_favorites_v1': jsonEncode([
        {'name': '1000m×4', 'plan': _plan.toJson()},
      ]),
      'workout_history_v1': jsonEncode([
        {'usedAt': '2026-09-20T06:00:00.000', 'plan': _plan.toJson()},
      ]),
    });
  });

  for (final (name, theme) in [
    ('明', buildAppTheme()),
    ('暗', buildAppDarkTheme()),
  ]) {
    testWidgets('小さい端末でも崩れず、5つのかたまりを順に並べる($name)', (tester) async {
      await _pump(tester, theme: theme, size: const Size(320, 568));
      expect(tester.takeException(), isNull);

      for (final title in ['メニューを選ぶ', 'ワーク', '本間レスト', 'セット', '数え方と始め方']) {
        await tester.scrollUntilVisible(
          find.text(title),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text(title), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('いまの内容は常に下へ出て、設定を変えると追従する', (tester) async {
    await _pump(tester, theme: buildAppTheme());
    final summary = find.byKey(const ValueKey('workout-setup-summary'));
    expect(tester.widget<Text>(summary).data, '500m×8 ・ r2:00');

    // 登録したメニューを選ぶと、その内容が入る。
    await tester.tap(find.text('★ 1000m×4'));
    await tester.pump();
    expect(tester.widget<Text>(summary).data, '1000m×4 ・ r3:00');
    expect(find.textContaining('ワーク合計 4000m'), findsOneWidget);

    // ワークの単位を変えると、長さも要約も切り替わる。
    await tester.tap(find.text('時間').first);
    await tester.pump();
    expect(tester.widget<Text>(summary).data, '5:00×4 ・ r3:00');
  });

  testWidgets('「このメニューで始める」は、いまの内容を返す', (tester) async {
    WorkoutPlan? result;
    await _pump(tester, theme: buildAppTheme(), onResult: (p) => result = p);
    await tester.tap(find.text('★ 1000m×4'));
    await tester.pump();
    await tester.tap(find.text('このメニューで始める'));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.sameMenuAs(_plan), isTrue);
  });
}
