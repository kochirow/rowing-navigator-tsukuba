import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/features/home_map/home_shell_bridge.dart';
import 'package:rowing_navigator/screens/home_shell.dart';
import 'package:rowing_navigator/theme/app_theme.dart';
import 'package:rowing_navigator/types/home_phase.dart';

/// 地図画面の代役。何回作り直されたかを数える。
class _MapStub extends StatefulWidget {
  final HomeShellBridge bridge;
  final List<String> lifecycle;

  const _MapStub({required this.bridge, required this.lifecycle});

  @override
  State<_MapStub> createState() => _MapStubState();
}

class _MapStubState extends State<_MapStub> {
  @override
  void initState() {
    super.initState();
    widget.lifecycle.add('init');
  }

  @override
  void dispose() {
    widget.lifecycle.add('dispose');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('地図')));
}

void main() {
  late List<String> lifecycle;
  late HomeShellBridge captured;

  Widget wrap() {
    lifecycle = <String>[];
    return MaterialApp(
      theme: buildAppTheme(),
      home: HomeShell(
        mapBuilder: (bridge) {
          captured = bridge;
          return _MapStub(bridge: bridge, lifecycle: lifecycle);
        },
      ),
    );
  }

  testWidgets('出艇前だけタブを出し、航行中・監視中は畳む', (tester) async {
    await tester.pumpWidget(wrap());

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('出艇'), findsOneWidget);
    expect(find.text('記録'), findsOneWidget);
    expect(find.text('準備'), findsOneWidget);

    // 航行が始まったら地図を全画面へ戻す。
    captured.phase.value = HomePhase.navigating;
    await tester.pump();
    expect(find.byType(NavigationBar), findsNothing);

    // 監視中も同じ。
    captured.phase.value = HomePhase.watching;
    await tester.pump();
    expect(find.byType(NavigationBar), findsNothing);

    // 終えて陸へ戻ればタブが返ってくる。
    captured.phase.value = HomePhase.ashore;
    await tester.pump();
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('タブを切り替えても地図画面は作り直されない', (tester) async {
    // 位置共有・警告・練習一括ログ・Wakelock は地図画面のフックが持つ。
    // タブのたびに作り直されると、そのすべてが止まって作り直される。
    await tester.pumpWidget(wrap());
    expect(lifecycle, ['init']);

    await tester.tap(find.text('準備'));
    await tester.pumpAndSettle();
    expect(find.text('出艇前に確かめること'), findsOneWidget);

    await tester.tap(find.text('出艇'));
    await tester.pumpAndSettle();

    // 航行の開始・終了を挟んでも同じ。
    captured.phase.value = HomePhase.navigating;
    await tester.pump();
    captured.phase.value = HomePhase.ashore;
    await tester.pump();

    expect(lifecycle, ['init']);
  });

  testWidgets('準備タブは戻るボタンを持たない', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.tap(find.text('準備'));
    await tester.pumpAndSettle();

    expect(find.byType(BackButton), findsNothing);
    // 出艇前にだけ置く操作が並ぶ。
    expect(find.text('既設危険区域を位置合わせ'), findsOneWidget);
    expect(find.text('警告の設定'), findsOneWidget);
    expect(find.text('チーム'), findsOneWidget);
    expect(find.text('端末とデータ'), findsOneWidget);
  });
}
