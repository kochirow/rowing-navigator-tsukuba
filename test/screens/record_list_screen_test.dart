import 'package:flutter/material.dart' hide Split;
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rowing_navigator/models/session_model.dart';
import 'package:rowing_navigator/screens/record_list_screen.dart';

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
    expect(find.text('記録一覧'), findsOneWidget);
  });

  testWidgets('詳細に分析・警告評価・診断共有の説明を表示する', (tester) async {
    final startedAt = DateTime(2026, 7, 23, 6);
    final base = session('detail', startedAt);
    final detailed = base.copyWith(
      summary: SessionSummary(
        totalDistanceMeters: 500,
        durationSec: 300,
        maxSpeed: 3,
        avgSpeed: 2.5,
        movingTimeSec: 240,
        restTimeSec: 60,
        splits250: [
          Split(index: 1, distanceMeters: 250, timeSec: 100),
        ],
        splits: [
          Split(index: 1, distanceMeters: 500, timeSec: 200),
        ],
        pieces: const [],
        alertCounts: const {'warning': 2},
      ),
      alertEvents: [
        AlertDiagnosticEvent(
          t: startedAt.add(const Duration(seconds: 10)),
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

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RecordDetailScreen(session: detailed),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ワーク時間'), findsOneWidget);
    expect(find.text('休憩時間'), findsOneWidget);
    expect(find.text('250m区間'), findsNothing);
    expect(find.text('500mスプリット'), findsNothing);
    expect(find.text('警告エピソード'), findsOneWidget);
    expect(find.text('診断データを共有'), findsOneWidget);

    await tester.tap(find.text('診断データを共有'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('診断ZIPには正確な航路'),
      findsOneWidget,
    );
    expect(find.text('共有先を選ぶ'), findsOneWidget);
  });
}
