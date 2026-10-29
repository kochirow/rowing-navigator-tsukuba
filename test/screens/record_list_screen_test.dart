import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Split;
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rowing_navigator/models/practice_log_model.dart';
import 'package:rowing_navigator/models/session_model.dart';
import 'package:rowing_navigator/screens/record_list_screen.dart';
import 'package:rowing_navigator/services/diagnostic_bundle_service.dart';
import 'package:rowing_navigator/services/practice_log_store_service.dart';
import 'package:rowing_navigator/services/session_store_service.dart';
import 'package:rowing_navigator/screens/record_replay/record_replay_screen.dart';
import 'package:share_plus/share_plus.dart';

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
    // 一覧は絞られていない。切替が集計カードの中にあるので、説明文は要らない。
    expect(find.text('これまでの記録は下の一覧から開けます'), findsNothing);
    expect(find.text('記録一覧'), findsOneWidget);
    expect(find.text('1件'), findsOneWidget);
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
    expect(find.text('2件'), findsOneWidget);
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
    expect(find.text('ワーク時間'), findsOneWidget);
    expect(find.text('練習時間'), findsOneWidget);
    expect(find.text('1セット目'), findsOneWidget);
    expect(find.textContaining('スプリット'), findsNothing,
        reason: 'ペースは「/500m」だけで書く（2026-09-24 利用者）');

    await tester.tap(find.text('1セット目'));
    await tester.pumpAndSettle();

    expect(find.textContaining('本の平均です'), findsOneWidget);
    expect(find.text('ワーク時間'), findsNothing, reason: '内訳のサマリは全体のときだけ');
    await tester.scrollUntilVisible(find.text('内訳（各本・区間）'), 200,
        scrollable:
            find.descendant(of: list, matching: find.byType(Scrollable)).first);
    expect(find.text('1本目'), findsNothing, reason: '内訳は既定で畳む');
  });

  testWidgets('診断ログは見出しのボタンからスクロールせずに送れる', (tester) async {
    await pumpReplay(tester, intervalSession(DateTime(2026, 8, 6, 6)));
    // 見出しのボタンは地図の上にあり、最初から見えている。
    final header = find.byKey(const Key('record-replay-send-log'));
    expect(header.hitTestable(), findsOneWidget);
    expect(find.text('ログを送る'), findsOneWidget);
    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(find.textContaining('診断ZIPには正確な航路'), findsOneWidget);
    expect(find.text('共有先を選ぶ'), findsOneWidget);
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
  });

  testWidgets('共有カードは警告の振り返りより上にあり、振り返りは件数の要約で始まる', (tester) async {
    await pumpReplay(tester, intervalSession(DateTime(2026, 8, 6, 6)));
    final scrollable =
        find.descendant(of: list, matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('警告の振り返り'), 300,
        scrollable: scrollable);
    expect(find.text('橋 1回'), findsOneWidget);
    expect(find.textContaining('地図で見る'), findsNothing, reason: '場面は既定で閉じる');
    final send = find.byKey(const Key('record-tools-send-log'));
    expect(send, findsOneWidget);
    expect(tester.getTopLeft(send).dy,
        lessThan(tester.getTopLeft(find.text('警告の振り返り')).dy));

    await tester.ensureVisible(send);
    await tester.pumpAndSettle();
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(find.textContaining('診断ZIPには正確な航路'), findsOneWidget);
  });

  testWidgets('航跡の無い記録でも詳細画面が落ちない', (tester) async {
    await pumpReplay(tester, session('empty', DateTime(2026, 8, 6, 6)));
    expect(find.text('この日の練習'), findsOneWidget);
  });

  Session eligible(String id, DateTime startedAt, {DateTime? sharedAt}) =>
      Session(
        id: id,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(minutes: 40)),
        boatTypeName: '1x',
        seatPosLabel: 'ストローク',
        points: const [],
        summary: SessionSummary(
          totalDistanceMeters: 6000,
          durationSec: 2400,
          movingTimeSec: 2000,
          maxSpeed: 4,
          avgSpeed: 3,
          splits: const [],
          pieces: const [],
          alertCounts: const {},
        ),
        diagnosticsSharedAt: sharedAt,
      );

  testWidgets('未送信のログのカードは、15分・2km以上の未送信があるときだけ出る', (tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: RecordListScreen(
          sessionsLoader: () async => [
            session('short', DateTime(2026, 7, 5)), // 10分・1km
            eligible('sent', DateTime(2026, 7, 6),
                sharedAt: DateTime(2026, 7, 6, 12)),
          ],
          clock: () => DateTime(2026, 7, 22),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pending-log-card')), findsNothing);
    expect(find.text('ログ未送信'), findsNothing);
  });

  testWidgets('送らずに送信済みにすると、保存してカードが消える', (tester) async {
    final store = _MemoryStore([
      eligible('a', DateTime(2026, 7, 5)),
      eligible('b', DateTime(2026, 7, 6)),
    ]);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: RecordListScreen(
          sessionStore: store,
          clock: () => DateTime(2026, 7, 22),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('未送信のログ 2件'), findsOneWidget);
    expect(find.text('ログ未送信'), findsWidgets);

    await tester.tap(find.text('まとめて送る'));
    await tester.pumpAndSettle();
    expect(find.text('2件を送る(共有先を選ぶ)'), findsOneWidget);
    // 1件を外すと、送る件数も減る。
    await tester.tap(find.byKey(const Key('bulk-log-b')));
    await tester.pump();
    expect(find.text('1件を送る(共有先を選ぶ)'), findsOneWidget);

    await tester.tap(find.text('送らずに送信済みにする'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1件を送信済みにしました'), findsOneWidget);
    expect(find.text('未送信のログ 1件'), findsOneWidget);
    expect(store.byId['a']!.isDiagnosticsShared, isTrue);
    expect(store.byId['b']!.isDiagnosticsShared, isFalse);
  });

  PracticeLog monitorLog(String id, DateTime startedAt,
          {int minutes = 40,
          bool complete = true,
          DateTime? sharedAt,
          int live = 20}) =>
      PracticeLog(
        id: id,
        teamId: 'team',
        recordedBy: 'observer',
        startedAt: startedAt,
        endedAt: complete ? startedAt.add(Duration(minutes: minutes)) : null,
        isComplete: complete,
        livePointCount: live,
        diagnosticsSharedAt: sharedAt,
      );

  Widget screen({
    List<Session> sessions = const [],
    required _MemoryPracticeStore practiceStore,
    SessionStoreService? store,
  }) =>
      ProviderScope(
        child: MaterialApp(
          home: RecordListScreen(
            sessionsLoader: store == null ? () async => sessions : null,
            sessionStore: store,
            practiceLogStore: practiceStore,
            clock: () => DateTime(2026, 7, 22),
          ),
        ),
      );

  testWidgets('練習記録が無くても、未送信の監視ログがあればカードを出す', (tester) async {
    final practiceStore = _MemoryPracticeStore([
      monitorLog('practice_20260705_060000', DateTime.utc(2026, 7, 5, 6)),
      monitorLog('practice_20260706_060000', DateTime.utc(2026, 7, 6, 6),
          sharedAt: DateTime.utc(2026, 7, 7)), // 送信済み
      monitorLog('practice_20260707_060000', DateTime.utc(2026, 7, 7, 6),
          minutes: 9), // 短い
      monitorLog('practice_20260709_060000', DateTime.utc(2026, 7, 9, 6),
          live: 0), // 航行した艇がいない
      monitorLog('practice_20260708_060000', DateTime.utc(2026, 7, 8, 6),
          complete: false), // 記録中
    ]);
    await tester.pumpWidget(screen(practiceStore: practiceStore));
    await tester.pumpAndSettle();
    expect(find.text('未送信のログ 1件'), findsOneWidget);
    expect(find.text('10分以上の監視ログ'), findsOneWidget);
    expect(find.text('まだ記録がありません'), findsNothing);
  });

  testWidgets('監視ログも練習記録も無いときは、これまでの空の画面のまま', (tester) async {
    await tester.pumpWidget(screen(practiceStore: _MemoryPracticeStore([])));
    await tester.pumpAndSettle();
    expect(find.text('まだ記録がありません'), findsOneWidget);
    expect(find.byKey(const Key('pending-log-card')), findsNothing);
  });

  testWidgets('監視ログの読み込みに失敗しても、練習記録の一覧とカードは出る', (tester) async {
    final practiceStore = _MemoryPracticeStore([], failList: true);
    await tester.pumpWidget(screen(
      practiceStore: practiceStore,
      sessions: [eligible('a', DateTime(2026, 7, 5))],
    ));
    await tester.pumpAndSettle();
    expect(find.text('未送信のログ 1件'), findsOneWidget);
    expect(find.text('15分・2km以上の練習'), findsOneWidget);
  });

  testWidgets('練習記録と監視ログを合わせて数え、送らずに送信済みにすると両方に印が付く', (tester) async {
    final practiceStore = _MemoryPracticeStore([
      monitorLog('practice_20260705_060000', DateTime.utc(2026, 7, 5, 6)),
      monitorLog('practice_20260706_060000', DateTime.utc(2026, 7, 6, 6)),
    ]);
    final store = _MemoryStore([eligible('a', DateTime(2026, 7, 5))]);
    await tester.pumpWidget(screen(practiceStore: practiceStore, store: store));
    await tester.pumpAndSettle();
    expect(find.text('未送信のログ 3件'), findsOneWidget);
    expect(find.text('練習記録 1件・監視ログ 2件'), findsOneWidget);

    await tester.tap(find.text('まとめて送る'));
    await tester.pumpAndSettle();
    expect(find.text('3件を送る(共有先を選ぶ)'), findsOneWidget);
    expect(find.byKey(const Key('bulk-log-anonymize')), findsOneWidget);
    // 監視ログを1件外すと、送る件数も減る。
    await tester
        .tap(find.byKey(const Key('bulk-practice-practice_20260706_060000')));
    await tester.pump();
    expect(find.text('2件を送る(共有先を選ぶ)'), findsOneWidget);

    await tester.tap(find.text('送らずに送信済みにする'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2件を送信済みにしました'), findsOneWidget);
    expect(store.byId['a']!.isDiagnosticsShared, isTrue);
    expect(practiceStore.shared.keys, ['practice_20260705_060000']);
    // 外した1件だけが未送信で残る。
    expect(find.text('未送信のログ 1件'), findsOneWidget);
    expect(find.text('10分以上の監視ログ'), findsOneWidget);
  });

  testWidgets('送信済みの印を保存できなかった分は、そう伝えて未送信のまま残す', (tester) async {
    final practiceStore = _MemoryPracticeStore(
      [monitorLog('practice_20260705_060000', DateTime.utc(2026, 7, 5, 6))],
      failMark: true,
    );
    await tester.pumpWidget(screen(practiceStore: practiceStore));
    await tester.pumpAndSettle();
    await tester.tap(find.text('まとめて送る'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('送らずに送信済みにする'));
    await tester.pumpAndSettle();
    expect(find.textContaining('0件を送信済みにしました'), findsOneWidget);
    expect(find.textContaining('1件は記録できず、未送信のままです'), findsOneWidget);
    expect(find.text('未送信のログ 1件'), findsOneWidget);
  });

  testWidgets('送ると監視ログも同じZIPへ渡し、届いたら送信済みにする', (tester) async {
    final practiceStore = _MemoryPracticeStore([
      monitorLog('practice_20260705_060000', DateTime.utc(2026, 7, 5, 6)),
    ]);
    final store = _MemoryStore([eligible('a', DateTime(2026, 7, 5))]);
    final bundles = _FakeBundleService();
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: RecordListScreen(
          sessionStore: store,
          practiceLogStore: practiceStore,
          bundleService: bundles,
          clock: () => DateTime(2026, 7, 22),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('まとめて送る'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bulk-log-send')));
    await tester.pumpAndSettle();

    expect(bundles.sessionIds, ['a']);
    expect(bundles.practiceLogIds, ['practice_20260705_060000']);
    // 既定では艇名を伏せて書き出す。
    expect(bundles.practiceFiles.single['practice_manifest.json'],
        contains('"anonymized": true'));
    expect(store.byId['a']!.isDiagnosticsShared, isTrue);
    expect(practiceStore.shared.keys, ['practice_20260705_060000']);
    expect(find.textContaining('2件を送信済みにしました'), findsOneWidget);
  });

  testWidgets('読めない監視ログがあるときは、送らず・印も付けずに理由を出す', (tester) async {
    final practiceStore = _MemoryPracticeStore(
      [monitorLog('practice_20260705_060000', DateTime.utc(2026, 7, 5, 6))],
      failRead: true,
    );
    final store = _MemoryStore([eligible('a', DateTime(2026, 7, 5))]);
    final bundles = _FakeBundleService();
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: RecordListScreen(
          sessionStore: store,
          practiceLogStore: practiceStore,
          bundleService: bundles,
          clock: () => DateTime(2026, 7, 22),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('まとめて送る'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bulk-log-send')));
    await tester.pumpAndSettle();

    expect(bundles.shareCalls, 0);
    expect(find.textContaining('を読み込めませんでした'), findsOneWidget);
    expect(store.byId['a']!.isDiagnosticsShared, isFalse);
    expect(practiceStore.shared, isEmpty);
    // 外せば、残りは送れる(送る前の画面に戻っている)。
    expect(find.byKey(const Key('bulk-log-send')), findsOneWidget);
  });
}

class _MemoryStore extends SessionStoreService {
  final Map<String, Session> byId;
  _MemoryStore(List<Session> sessions)
      : byId = {for (final s in sessions) s.id: s};

  @override
  Future<void> saveSession(Session session) async => byId[session.id] = session;

  @override
  Future<List<Session>> listSessions() async =>
      byId.values.toList()..sort((a, b) => b.startedAt.compareTo(a.startedAt));
}

class _MemoryPracticeStore extends PracticeLogStoreService {
  final List<PracticeLog> logs;
  final bool failList;
  final bool failMark;
  final bool failRead;
  final Map<String, DateTime> shared = {};

  _MemoryPracticeStore(this.logs,
      {this.failList = false, this.failMark = false, this.failRead = false});

  @override
  Future<
      ({
        PracticeLog log,
        List<PracticeLogPoint> points,
        List<PracticeLogEvent> events
      })> read(String id) async {
    if (failRead) throw const FileSystemException('broken');
    return (
      log: logs.firstWhere((l) => l.id == id),
      points: <PracticeLogPoint>[],
      events: <PracticeLogEvent>[],
    );
  }

  @override
  Future<List<PracticeLog>> list() async {
    if (failList) throw const FileSystemException('unreadable');
    return [
      for (final l in logs)
        shared.containsKey(l.id)
            ? l.copyWith(diagnosticsSharedAt: () => shared[l.id])
            : l
    ];
  }

  @override
  Future<void> markDiagnosticsShared(String id, DateTime at) async {
    if (failMark) throw const FileSystemException('read only');
    shared[id] = at;
  }
}

class _FakeBundleService extends DiagnosticBundleService {
  List<String> sessionIds = [];
  List<String> practiceLogIds = [];
  List<Map<String, String>> practiceFiles = [];
  int shareCalls = 0;

  @override
  Future<List<DiagnosticBundle>> buildBundlesInBackground(
      List<Session> sessions,
      {List<PracticeLogBundleInput> practiceLogs = const []}) async {
    sessionIds = [for (final s in sessions) s.id];
    practiceLogIds = [for (final p in practiceLogs) p.log.id];
    practiceFiles = [for (final p in practiceLogs) p.files];
    return [
      DiagnosticBundle(
        fileName: 'x.zip',
        bytes: Uint8List(1),
        sessionIds: sessionIds,
        practiceLogIds: practiceLogIds,
      ),
    ];
  }

  @override
  Future<ShareResult> share(List<DiagnosticBundle> bundles,
      {required Rect sharePositionOrigin}) async {
    shareCalls++;
    return const ShareResult('', ShareResultStatus.success);
  }
}
