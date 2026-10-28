import 'package:flutter/material.dart' hide Split;
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/session_model.dart';
import 'package:rowing_navigator/screens/record_replay/replay_analysis.dart';
import 'package:rowing_navigator/screens/record_replay/replay_controller.dart';
import 'package:rowing_navigator/screens/record_replay/widgets/record_tools.dart';
import 'package:rowing_navigator/screens/record_replay/widgets/selection_card.dart';
import 'package:rowing_navigator/services/gpx_export_service.dart';
import 'package:rowing_navigator/services/session_store_service.dart';

import 'replay_controller_test.dart' show practice;

AlertDiagnosticEvent _alert(DateTime t, String id, String category,
        {int risk = 1}) =>
    AlertDiagnosticEvent(
      t: t,
      event: 'observation',
      alertId: id,
      detectorId: 'test',
      category: category,
      phase: 'alerting',
      isPrimary: true,
      riskLevel: risk,
      currentOverlap: false,
      confidence: 1,
      dataQuality: 'good',
    );

Session _withAlerts() {
  final base = practice();
  final t0 = base.startedAt;
  return base.copyWith(alertEvents: [
    for (var i = 0; i < 7; i++)
      _alert(t0.add(Duration(seconds: 10 + i * 20)), 'shore-$i', 'shore',
          risk: i == 6 ? 3 : 1),
    for (var i = 0; i < 3; i++)
      _alert(t0.add(Duration(seconds: 15 + i * 20)), 'net-$i',
          'position_sharing_unavailable'),
  ]);
}

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: ListView(children: [child])),
    );

void main() {
  testWidgets('警告は種類ごとの件数だけを出し、場面は開いたときに上位5件だけ出す', (tester) async {
    // 全部の行を作らせるため縦に長い画面にする(一覧は見える分だけ作る)。
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = _withAlerts();
    await tester.pumpWidget(_host(AlertReviewCard(
      session: session,
      onSeekTo: (_) {},
      onRate: (_, __) {},
      onRateOverall: (_) {},
    )));

    expect(find.text('岸 7回'), findsOneWidget);
    // システム系は件数だけ出し、評価の対象にしない。
    expect(find.textContaining('GPS・通信の表示 3回'), findsOneWidget);
    expect(find.textContaining('地図で見る'), findsNothing);
    expect(find.text('ちょうどよい'), findsOneWidget);

    await tester.tap(find.byKey(const Key('alert-review-toggle')));
    await tester.pump();
    expect(find.textContaining('地図で見る'), findsNWidgets(5));
    // 危険度の高い場面が先頭に来る。
    final first = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((r) => r.text.toPlainText())
        .firstWhere((t) => t.contains('地図で見る'));
    expect(first, contains('危険度3'));
    expect(find.text('残り 2件を表示'), findsOneWidget);

    await tester.ensureVisible(find.text('残り 2件を表示'));
    await tester.tap(find.text('残り 2件を表示'));
    await tester.pump();
    expect(find.textContaining('地図で見る'), findsNWidgets(7));
  });

  testWidgets('システム系の警告しか無いときは全体評価も場面も出さない', (tester) async {
    final base = practice();
    final session = base.copyWith(alertEvents: [
      _alert(base.startedAt, 'gps', 'gps_unavailable'),
    ]);
    await tester.pumpWidget(_host(AlertReviewCard(
      session: session,
      onSeekTo: (_) {},
      onRate: (_, __) {},
      onRateOverall: (_) {},
    )));
    expect(find.text('危険区域・他艇の警告はありませんでした'), findsOneWidget);
    expect(find.text('ちょうどよい'), findsNothing);
    expect(find.byKey(const Key('alert-review-toggle')), findsNothing);
  });

  testWidgets('診断ログを送るボタンは警告の振り返りより上にある', (tester) async {
    Rect? origin;
    await tester.pumpWidget(_host(RecordTools(
      session: _withAlerts(),
      onSessionChanged: (_) {},
      exporter: GpxExportService(),
      store: SessionStoreService(),
      onSeekTo: (_) {},
      onShareDiagnostics: (r) => origin = r,
    )));
    final send = find.byKey(const Key('record-tools-send-log'));
    expect(tester.getTopLeft(send).dy,
        lessThan(tester.getTopLeft(find.text('警告の振り返り')).dy));
    expect(find.text('未送信'), findsOneWidget);

    await tester.tap(send);
    expect(origin, isNotNull);
    expect(origin!.isEmpty, isFalse);
  });

  testWidgets('送信済みなら時刻と「未送信に戻す」を出す', (tester) async {
    Session? changed;
    final session = _withAlerts()
        .copyWith(diagnosticsSharedAt: () => DateTime(2026, 10, 28, 18, 2));
    await tester.pumpWidget(_host(RecordTools(
      session: session,
      onSessionChanged: (s) => changed = s,
      exporter: GpxExportService(),
      store: SessionStoreService(
          documentsDirectoryProvider: () async => throw 'no disk'),
      onSeekTo: (_) {},
      onShareDiagnostics: (_) {},
    )));
    expect(find.text('送信済み 10/28 18:02'), findsOneWidget);
    await tester.tap(find.text('未送信に戻す'));
    await tester.pump();
    // 保存に失敗したら元へ戻す(最後に渡すのは元の記録)。
    expect(changed!.diagnosticsSharedAt, isNotNull);
  });

  testWidgets('全体選択では「時間軸を拡大」を出さず、「結果を共有」は起点を渡す', (tester) async {
    final controller = ReplayController(ReplayAnalysis.compute(practice()));
    addTearDown(controller.dispose);
    Rect? origin;
    await tester.pumpWidget(_host(ListenableBuilder(
      listenable: controller,
      builder: (_, __) =>
          SelectionCard(controller: controller, onShare: (r) => origin = r),
    )));
    expect(find.text('この日の練習'), findsOneWidget);
    expect(find.text('時間軸を拡大'), findsNothing);
    expect(find.text('絞る'), findsNothing);

    await tester.tap(find.text('結果を共有'));
    expect(origin, isNotNull);
    expect(origin!.isEmpty, isFalse);

    controller.selectSet(controller.analysis.sets.first);
    await tester.pump();
    expect(find.text('時間軸を拡大'), findsOneWidget);
  });
}
