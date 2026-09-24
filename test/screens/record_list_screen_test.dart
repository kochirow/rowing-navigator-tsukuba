import 'package:flutter/material.dart' hide Split;
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rowing_navigator/models/session_model.dart';
import 'package:rowing_navigator/screens/record_list_screen.dart';
import 'package:rowing_navigator/screens/record_replay/record_replay_screen.dart';

void main() {
  Session session(String id, DateTime startedAt) => Session(
        id: id,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(minutes: 10)),
        boatTypeName: '1x',
        seatPosLabel: 'ストローク',
        points: const [],
        summary: SessionSummary(
          totalDistanceMeters: 1000,
          durationSec: 600,
          maxSpeed: 3,
          avgSpeed: 2.5,
          splits: const [],
          pieces: const [],
          alertCounts: const {},
        ),
      );

  testWidgets('既定は今月で、全期間へ切り替えると集計だけが更新される', (tester) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
            child: RecordListScreen(
              sessionsLoader: () async => [
                session('july', DateTime(2026, 7, 5)),
                session('june', DateTime(2026, 6, 30)),
              ],
              clock: () => DateTime(2026, 7, 22),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 本'), findsOneWidget);
    expect(find.text('1.0 km'), findsWidgets);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('全期間'));
    await tester.pumpAndSettle();
    expect(find.text('2 本'), findsOneWidget);
    expect(find.text('2.0 km'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('選択期間に記録がない場合は共通空状態を表示する', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RecordListScreen(
            sessionsLoader: () async => [
              session('june', DateTime(2026, 6, 30)),
            ],
            clock: () => DateTime(2026, 7, 22),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('今月の記録はありません'), findsOneWidget);
    // 一覧は絞られていないので、「切り替えると見られる」とは書かない。
    expect(find.text('これまでの記録は下の一覧から開けます'), findsOneWidget);
    expect(find.text('記録一覧'), findsOneWidget);
    expect(find.text('全期間・1件'), findsOneWidget);
  });

  testWidgets('艇種は内部名ではなく「8+」で出し、一覧が全期間であることを示す', (tester) async {
    final eight = Session(
      id: 'eight',
      startedAt: DateTime(2026, 7, 5),
      endedAt: DateTime(2026, 7, 5, 0, 10),
      boatTypeName: 'r_8p',
      seatPosLabel: '7',
      points: const [],
      summary: SessionSummary(
        totalDistanceMeters: 1000,
        durationSec: 600,
        maxSpeed: 3,
        avgSpeed: 2.5,
        splits: const [],
        pieces: const [],
        alertCounts: const {},
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RecordListScreen(
            sessionsLoader: () async => [
              eight,
              session('june', DateTime(2026, 6, 30)),
            ],
            clock: () => DateTime(2026, 7, 22),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('r_8p'), findsNothing);
    expect(find.text('8+'), findsOneWidget);
    // 集計は今月(1本)だが、一覧は期間によらず全件。
    expect(find.text('1 本'), findsOneWidget);
    expect(find.text('全期間・2件'), findsOneWidget);
  });

  /// ハイレート×5本（40秒・5m/s・SR34）をSR20のパドル（80秒・2.3m/s）でつなぐ練習。
  Session intervalSession(DateTime startedAt) {
    final points = <TrackPoint>[];
    var y = 0.0;
    var t = 0;
    void leg(int seconds, double v, double? spm) {
      for (var k = 0; k < seconds; k++) {
        y += v;
        final lat = 36.08 + y / 111320.0;
        points.add(TrackPoint(
          t: startedAt.add(Duration(seconds: t)),
          elapsedMs: t * 1000,
          lat: lat,
          lng: 140.21,
          speed: v,
          heading: 0,
          spm: spm,
          safetyLevel: 'safe',
          rawLat: lat,
          rawLng: 140.21,
          rawGnssSpeedMetersPerSecond: v,
          speedAccuracyMetersPerSecond: 0.5,
        ));
        t++;
      }
    }

    leg(60, 0, null);
    for (var k = 0; k < 5; k++) {
      leg(40, 5.0, 34);
      leg(80, 2.3, 20);
    }
    leg(60, 0, null);
    return Session(
      id: 'interval',
      startedAt: startedAt,
      endedAt: startedAt.add(Duration(seconds: t)),
      boatTypeName: 'r_4x',
      seatPosLabel: 'バウ',
      points: points,
      summary: SessionSummary(
        totalDistanceMeters: 0,
        durationSec: t.toDouble(),
        maxSpeed: 5,
        avgSpeed: 3,
        splits: const [],
        pieces: const [],
        alertCounts: const {},
      ),
      alertEvents: [
        AlertDiagnosticEvent(
          t: startedAt.add(const Duration(seconds: 100)),
          event: 'observation',
          alertId: 'bridge-1',
          detectorId: 'static_collision',
          category: 'bridge',
          phase: 'alerting',
          isPrimary: true,
          riskLevel: 2,
          currentOverlap: false,
          confidence: 1,
          dataQuality: 'good',
        ),
      ],
    );
  }

  Future<void> pumpReplay(WidgetTester tester, Session s) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RecordReplayScreen(
            session: s,
            mapBuilderForTest: (overlay) => Stack(
                children: [const ColoredBox(color: Colors.black), overlay]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final list = find.byKey(const Key('record-replay-scroll'));

  testWidgets('詳細は全体のサマリから始まり、セットのカードを選ぶとレストを除いた平均になる', (tester) async {
    await pumpReplay(tester, intervalSession(DateTime(2026, 8, 6, 6)));

    expect(find.text('この日の練習'), findsOneWidget);
    expect(find.text('漕いでいた時間'), findsOneWidget);
    expect(find.text('練習時間'), findsOneWidget);
    expect(find.text('1セット目'), findsOneWidget);
    expect(find.textContaining('スプリット'), findsNothing,
        reason: 'ペースは「/500m」だけで書く（2026-09-24 利用者）');

    await tester.tap(find.text('1セット目'));
    await tester.pumpAndSettle();

    expect(find.textContaining('本の平均です'), findsOneWidget);
    expect(find.text('漕いでいた時間'), findsNothing, reason: '内訳のサマリは全体のときだけ');
    await tester.scrollUntilVisible(find.text('内訳（各本・区間）'), 200,
        scrollable:
            find.descendant(of: list, matching: find.byType(Scrollable)).first);
    expect(find.text('1本目'), findsNothing, reason: '内訳は既定で畳む');
  });

  testWidgets('警告エピソードと診断データの共有を旧画面から引き継ぐ', (tester) async {
    await pumpReplay(tester, intervalSession(DateTime(2026, 8, 6, 6)));
    final scrollable =
        find.descendant(of: list, matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('診断データを共有'), 300,
        scrollable: scrollable);
    expect(find.text('警告エピソード'), findsOneWidget);

    await tester.ensureVisible(find.text('診断データを共有'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('診断データを共有'));
    await tester.pumpAndSettle();
    expect(find.textContaining('診断ZIPには正確な航路'), findsOneWidget);
    expect(find.text('共有先を選ぶ'), findsOneWidget);
  });

  testWidgets('航跡の無い記録でも詳細画面が落ちない', (tester) async {
    await pumpReplay(tester, session('empty', DateTime(2026, 8, 6, 6)));
    expect(find.text('この日の練習'), findsOneWidget);
  });
}
