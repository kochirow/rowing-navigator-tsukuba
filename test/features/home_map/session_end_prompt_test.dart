import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/features/home_map/session_end_prompt.dart';
import 'package:rowing_navigator/models/session_model.dart';
import 'package:rowing_navigator/services/practice_log_store_service.dart';
import 'package:rowing_navigator/services/session_store_service.dart';
import 'package:rowing_navigator/theme/app_theme.dart';

final _start = DateTime.utc(2026, 11, 2, 21, 17);

Session _session({bool recovered = false}) => Session(
      id: 'session-${recovered ? 'r' : 'n'}',
      startedAt: _start,
      endedAt: _start.add(const Duration(minutes: 41)),
      boatTypeName: 'r_4p',
      seatPosLabel: 'cox',
      points: const [],
      summary: SessionSummary(
        totalDistanceMeters: 2200,
        durationSec: 19 * 60,
        movingTimeSec: 19 * 60,
        maxSpeed: 3,
        avgSpeed: 2,
        splits: const [],
        pieces: const [],
        alertCounts: const {},
      ),
      endReason: recovered ? Session.endReasonRecoveredAfterTermination : null,
      diagnosticEvents: [
        for (final category in ['other_boat', 'shore', 'shore'])
          SessionDiagnosticEvent(
            t: _start,
            type: 'warning_presentation_requested',
            details: {'category': category},
          ),
      ],
    );

/// 端末のファイルを使わない記録の置き場(テストの時間の中で読み書きを終える)。
class _MemorySessions extends SessionStoreService {
  final Map<String, Session> saved = {};

  @override
  Future<void> saveSession(Session session) async =>
      saved[session.id] = session;

  @override
  Future<Session?> loadSession(String id) async => saved[id];
}

class _NoPracticeLogs extends PracticeLogStoreService {
  @override
  Future<List<String>> recoverIncompleteLogs(
          {required DateTime startedBefore}) async =>
      const [];
}

class _Host extends HookWidget {
  final bool ready;
  final SessionStoreService sessions;
  final PracticeLogStoreService logs;
  const _Host({
    required this.ready,
    required this.sessions,
    required this.logs,
  });

  @override
  Widget build(BuildContext context) {
    useSessionEndPrompt(context,
        ready: ready, sessionStore: sessions, logStore: logs);
    return const Scaffold(body: Text('地図'));
  }
}

void main() {
  late _MemorySessions sessions;
  late PracticeLogStoreService logs;

  setUp(() {
    sessions = _MemorySessions();
    logs = _NoPracticeLogs();
  });

  Future<void> pumpHost(WidgetTester tester, {required bool ready}) =>
      tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: _Host(ready: ready, sessions: sessions, logs: logs),
      ));

  Future<void> settle(WidgetTester tester) => tester.pumpAndSettle();

  testWidgets('航行を終えると出艇前の地図にシートが出て、評価をその場で保存する', (tester) async {
    await pumpHost(tester, ready: true);
    final session = _session();
    await sessions.saveFinishedSession(session);
    await settle(tester);

    expect(find.text('今日の練習'), findsOneWidget);
    expect(find.text('2.2 km ・ 19分'), findsOneWidget);
    expect(find.text('鳴った警告：岸 2・他艇 1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('feedback-timing-1')));
    await settle(tester);
    var saved = sessions.saved[session.id]!;
    expect(saved.userFeedback?.timingOffset, 1);
    expect(saved.endPromptShownAt, isNotNull);

    // もう一度押すと未選択に戻る。
    await tester.tap(find.byKey(const Key('feedback-timing-1')));
    await settle(tester);
    saved = sessions.saved[session.id]!;
    expect(saved.userFeedback?.timingOffset, isNull);

    await tester.tap(find.byKey(const Key('today-record-later')));
    await settle(tester);
    expect(find.text('今日の練習'), findsNothing);
    saved = sessions.saved[session.id]!;
    expect(saved.diagnosticEvents.map((e) => e.type),
        containsAll(['session_end_prompt_shown', 'session_end_prompt_closed']));
    expect(saved.diagnosticEvents.last.details['action'], 'later');
  });

  testWidgets('航行中・監視中には出さず、出艇前に戻ったら出す', (tester) async {
    await pumpHost(tester, ready: false);
    await sessions.saveFinishedSession(_session());
    await settle(tester);
    expect(find.text('今日の練習'), findsNothing);

    await pumpHost(tester, ready: true);
    await settle(tester);
    expect(find.text('今日の練習'), findsOneWidget);
  });

  testWidgets('一度出した記録には二度と出さない', (tester) async {
    await pumpHost(tester, ready: true);
    final session = _session();
    await sessions.saveFinishedSession(session);
    await settle(tester);
    await tester.tap(find.byKey(const Key('today-record-later')));
    await settle(tester);

    await sessions.saveFinishedSession(sessions.saved[session.id]!);
    await settle(tester);
    expect(find.text('今日の練習'), findsNothing);
  });

  testWidgets('途切れた記録には、途切れたことと最後の記録の時刻を出す', (tester) async {
    await pumpHost(tester, ready: true);
    await sessions.saveFinishedSession(_session(recovered: true));
    await settle(tester);
    final notice = tester
        .widget<Text>(find.byKey(const Key('today-record-recovered-notice')));
    final end = _start.add(const Duration(minutes: 41)).toLocal();
    final hhmm = '${end.hour.toString().padLeft(2, '0')}:'
        '${end.minute.toString().padLeft(2, '0')}';
    expect(notice.data, contains('終了ボタンを押さずに終わりました（$hhmm まで記録）'));
  });

  testWidgets('ひとことは入力が止まって1秒後に保存し、閉じても失われない', (tester) async {
    await pumpHost(tester, ready: true);
    final session = _session();
    await sessions.saveFinishedSession(session);
    await settle(tester);

    await tester.enterText(
        find.byKey(const Key('feedback-comment')), '港を出るまで鳴っていた');
    await tester.pump(const Duration(milliseconds: 1100));
    await settle(tester);
    final saved = sessions.saved[session.id]!;
    expect(saved.userFeedback?.comment, '港を出るまで鳴っていた');
  });
}
