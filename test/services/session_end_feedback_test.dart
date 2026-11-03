import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/log_export_config.dart';
import 'package:rowing_navigator/models/practice_log_model.dart';
import 'package:rowing_navigator/models/session_model.dart';
import 'package:rowing_navigator/services/diagnostic_bundle_service.dart';
import 'package:rowing_navigator/services/gpx_export_service.dart';
import 'package:rowing_navigator/services/practice_log_export_service.dart';
import 'package:rowing_navigator/services/practice_log_store_service.dart';
import 'package:rowing_navigator/services/session_end_prompt_policy.dart';
import 'package:rowing_navigator/services/session_store_service.dart';

final _start = DateTime.utc(2026, 11, 2, 21, 17);

SessionSummary _summary({double distance = 0, double moving = 0}) =>
    SessionSummary(
      totalDistanceMeters: distance,
      durationSec: moving,
      movingTimeSec: moving,
      maxSpeed: 0,
      avgSpeed: 0,
      splits: const [],
      pieces: const [],
      alertCounts: const {},
    );

Session _session({
  bool isComplete = true,
  double distance = 500,
  double moving = 300,
  List<SessionDiagnosticEvent> events = const [],
  List<TrackPoint>? points,
  DateTime? sharedAt,
  DateTime? promptShownAt,
  SessionUserFeedback? feedback,
}) =>
    Session(
      id: '${_start.millisecondsSinceEpoch}',
      startedAt: _start,
      endedAt: _start.add(const Duration(minutes: 5)),
      boatTypeName: 'r_4p',
      seatPosLabel: 'cox',
      points: points ?? const [],
      summary: _summary(distance: distance, moving: moving),
      isComplete: isComplete,
      diagnosticEvents: events,
      diagnosticsSharedAt: sharedAt,
      endPromptShownAt: promptShownAt,
      userFeedback: feedback,
    );

SessionDiagnosticEvent _warning(String category, int second) =>
    SessionDiagnosticEvent(
      t: _start.add(Duration(seconds: second)),
      type: 'warning_presentation_requested',
      details: {'category': category, 'mode': 'loop'},
    );

void main() {
  group('評価とひとこと(R1-R7)', () {
    test('−2〜+2 の外は未入力として扱い、空のひとことは null にする', () {
      final feedback = SessionUserFeedback(
        timingOffset: 3,
        amountOffset: -2,
        comment: '   ',
        updatedAt: _start,
      );
      expect(feedback.timingOffset, isNull);
      expect(feedback.amountOffset, -2);
      expect(feedback.comment, isNull);
    });

    test('ひとことは上限で切り、保存・読み込みで値が変わらない', () {
      final long = 'あ' * (userFeedbackCommentMaxLength + 20);
      final feedback = SessionUserFeedback(
        timingOffset: 1,
        comment: long,
        updatedAt: _start,
      );
      expect(feedback.comment!.runes.length, userFeedbackCommentMaxLength);
      final restored = SessionUserFeedback.fromJson(
          jsonDecode(jsonEncode(feedback.toJson())));
      expect(restored!.timingOffset, 1);
      expect(restored.amountOffset, isNull);
      expect(restored.comment, feedback.comment);
    });

    test('人が読む形は「少し遅かった（+1）」、未入力は「未入力」', () {
      expect(FeedbackScale.timing.describe(1), '少し遅かった（+1）');
      expect(FeedbackScale.amount.describe(2), '多すぎた（+2）');
      expect(FeedbackScale.timing.describe(0), 'ちょうどよい（0）');
      expect(FeedbackScale.amount.describe(null), '未入力');
    });

    test('記録の新しい項目は保存して読み直しても残る', () {
      final session = _session(
        feedback: SessionUserFeedback(amountOffset: 2, updatedAt: _start),
        promptShownAt: _start,
      ).copyWith(endReason: Session.endReasonRecoveredAfterTermination);
      final restored =
          Session.fromJson(jsonDecode(jsonEncode(session.toJson())));
      expect(restored.userFeedback!.amountOffset, 2);
      expect(restored.endPromptShownAt, isNotNull);
      expect(restored.wasRecoveredAfterTermination, isTrue);
    });
  });

  group('シートを出すか(R1-R2・R1-R12)', () {
    test('まとめて送る対象(15分・2km以上)なら出す', () {
      final s = _session(
          distance: bulkLogExportMinDistanceMeters,
          moving: bulkLogExportMinPracticeSec);
      expect(shouldPromptSessionEnd(s), isTrue);
    });

    test('短い練習でも、警告音が1回でも鳴ったら出す', () {
      expect(shouldPromptSessionEnd(_session()), isFalse);
      expect(shouldPromptSessionEnd(_session(events: [_warning('shore', 10)])),
          sessionEndPromptAfterAnyWarningAudio);
    });

    test('送信済み・一度出した・未完了の記録には出さない', () {
      final events = [_warning('shore', 10)];
      expect(shouldPromptSessionEnd(_session(events: events, sharedAt: _start)),
          isFalse);
      expect(
          shouldPromptSessionEnd(
              _session(events: events, promptShownAt: _start)),
          isFalse);
      expect(
          shouldPromptSessionEnd(_session(events: events, isComplete: false)),
          isFalse);
    });

    test('鳴った警告を種類ごとに数える', () {
      final counts = warningAudioCountsOf(_session(events: [
        _warning('other_boat', 1),
        _warning('shore', 2),
        _warning('other_boat', 3),
        SessionDiagnosticEvent(
            t: _start, type: 'warning_presentation_cleared', details: {}),
      ]));
      expect(counts, {'other_boat': 2, 'shore': 1});
    });
  });

  group('途切れた記録を完了に直す(R1-R14)', () {
    late Directory dir;
    late SessionStoreService store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('rowing-recovery-');
      store = SessionStoreService(documentsDirectoryProvider: () async => dir);
    });
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('最後の記録の時刻で確定し、直したことを残す', () {
      final lastPointAt = _start.add(const Duration(minutes: 41, seconds: 28));
      final incomplete = _session(
        isComplete: false,
        points: [
          TrackPoint(
              t: _start,
              lat: 36.08,
              lng: 140.21,
              speed: 0,
              heading: 0,
              safetyLevel: 'safe'),
          TrackPoint(
              t: lastPointAt,
              lat: 36.081,
              lng: 140.211,
              speed: 1,
              heading: 0,
              safetyLevel: 'safe'),
        ],
        events: [
          SessionDiagnosticEvent(
              sequence: 7,
              t: lastPointAt.subtract(const Duration(seconds: 5)),
              type: 'diagnostic_heartbeat',
              details: const {'lifecycle': 'paused'}),
        ],
      );
      final now = DateTime.utc(2026, 11, 3, 3, 0, 57);
      final recovered =
          SessionStoreService.recoveredSession(incomplete, now: now);
      expect(recovered.isComplete, isTrue);
      expect(recovered.endedAt, lastPointAt);
      expect(recovered.wasRecoveredAfterTermination, isTrue);
      final event = recovered.diagnosticEvents.last;
      expect(event.type, 'session_recovery_detected');
      expect(event.sequence, 8);
      expect(event.details['recoveredEndedAt'], lastPointAt.toIso8601String());
      expect(event.details['lastLifecycle'], 'paused');
    });

    test('いま記録中の航行は触らず、確定したものを知らせる', () async {
      final old = _session(isComplete: false);
      final current = Session(
        id: 'current',
        startedAt: DateTime.utc(2026, 11, 4, 6),
        endedAt: DateTime.utc(2026, 11, 4, 6, 1),
        boatTypeName: 'r_1x',
        seatPosLabel: '1',
        points: const [],
        summary: _summary(),
        isComplete: false,
      );
      await store.saveSession(old);
      await store.saveSession(current);
      final finished = <String>[];
      final subscription =
          SessionStoreService.finishedSessionIds.listen(finished.add);
      addTearDown(subscription.cancel);

      final outcomes = await store.recoverIncompleteSessions(
        now: DateTime.utc(2026, 11, 4, 6, 2),
        startedBefore: DateTime.utc(2026, 11, 4, 6),
      );
      await Future<void>.delayed(Duration.zero);

      expect(outcomes.map((o) => o.sessionId), [old.id]);
      expect(finished, [old.id]);
      expect((await store.loadSession(old.id))!.isComplete, isTrue);
      expect((await store.loadSession('current'))!.isComplete, isFalse);
    });

    test('終了操作の保存は知らせ、評価の保存は知らせない', () async {
      final finished = <String>[];
      final subscription =
          SessionStoreService.finishedSessionIds.listen(finished.add);
      addTearDown(subscription.cancel);
      final session = _session();
      await store.saveFinishedSession(session);
      await store.saveSession(session.copyWith(
          userFeedback: () =>
              SessionUserFeedback(timingOffset: 1, updatedAt: _start)));
      await Future<void>.delayed(Duration.zero);
      expect(finished, [session.id]);
    });
  });

  group('共有するログに評価を含める(R1-R8)', () {
    test('manifest に userFeedback、feedback.txt に人が読める評価を入れる', () {
      final session = _session(
          feedback: SessionUserFeedback(
              timingOffset: 1, comment: '港を出るまで鳴っていた', updatedAt: _start));
      final files = GpxExportService().buildDiagnosticFiles(session);
      final manifest = jsonDecode(files['manifest.json']!) as Map;
      expect(manifest['userFeedback'], {
        'timingOffset': 1,
        'amountOffset': null,
        'comment': '港を出るまで鳴っていた',
        'updatedAt': _start.toIso8601String(),
      });
      final text = files['feedback.txt']!;
      expect(text, contains('警告のタイミング：少し遅かった（+1）'));
      expect(text, contains('警告の量：未入力'));
      expect(text, contains('ひとこと：港を出るまで鳴っていた'));
    });

    test('未入力の記録でも項目は null で出す', () {
      final files = GpxExportService().buildDiagnosticFiles(_session());
      final manifest = jsonDecode(files['manifest.json']!) as Map;
      expect((manifest['userFeedback'] as Map)['timingOffset'], isNull);
      expect(files['feedback.txt'], contains('ひとこと：未入力'));
    });

    test('一括送信の bundle_manifest にも記録ごとの評価が入る', () {
      final session = _session(
          feedback: SessionUserFeedback(amountOffset: 2, updatedAt: _start));
      final bundles =
          DiagnosticBundleService.buildBundles([session], createdAt: _start);
      final archive = ZipDecoder().decodeBytes(bundles.single.bytes);
      final manifest = jsonDecode(utf8.decode(
              archive.findFile('bundle_manifest.json')!.content as List<int>))
          as Map<String, dynamic>;
      final entry = (manifest['sessions'] as List).single as Map;
      expect(entry['userFeedback'],
          {'timingOffset': null, 'amountOffset': 2, 'comment': null});
      expect(archive.findFile('rowing_diagnostics_${session.id}/feedback.txt'),
          isNotNull);
    });
  });

  group('監視ログ(R1-R5・R1-R16)', () {
    late Directory dir;
    late PracticeLogStoreService store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('rowing-practice-recovery-');
      store =
          PracticeLogStoreService(documentsDirectoryProvider: () async => dir);
    });
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('途切れた監視ログを最後の記録の時刻で確定する', () async {
      final log = PracticeLog(
          id: 'practice_20261103_061700',
          teamId: 't',
          recordedBy: 'u',
          startedAt: _start,
          isComplete: false);
      await store.create(log);
      final lastAt = _start.add(const Duration(minutes: 30));
      await store.append(log.id, points: [
        PracticeLogPoint(
            t: lastAt,
            source: PracticeLogSource.live,
            boatId: 'b',
            lat: 36,
            lng: 140,
            ageSec: 0),
      ]);
      final finished = <String>[];
      final subscription =
          PracticeLogStoreService.finishedLogIds.listen(finished.add);
      addTearDown(subscription.cancel);

      final recovered = await store.recoverIncompleteLogs(
          startedBefore: DateTime.utc(2026, 11, 4));
      await Future<void>.delayed(Duration.zero);

      expect(recovered, [log.id]);
      expect(finished, [log.id]);
      final saved = (await store.list()).single;
      expect(saved.isComplete, isTrue);
      expect(saved.endedAt, lastAt);
      expect(saved.livePointCount, 1);
      expect(saved.wasRecoveredAfterTermination, isTrue);
    });

    test('ひとことは meta.json に残り、監視ログの書き出しにも入る', () async {
      final log = PracticeLog(
          id: 'practice_20261103_061800',
          teamId: 't',
          recordedBy: 'u',
          startedAt: _start,
          isComplete: true);
      await store.create(log);
      await store.updateMeta(
          log.id,
          (current) => current.copyWith(
              userComment: () => '出口で他艇の知らせが多い', userCommentUpdatedAt: _start));
      final saved = (await store.list()).single;
      expect(saved.userComment, '出口で他艇の知らせが多い');
      final files =
          PracticeLogExportService().buildFiles(saved, const [], const []);
      expect(files['feedback.txt'], contains('ひとこと：出口で他艇の知らせが多い'));
      final manifest = jsonDecode(files['practice_manifest.json']!) as Map;
      expect(manifest['userComment'], '出口で他艇の知らせが多い');
      expect(manifest.containsKey('endPromptShownAt'), isFalse);
    });
  });
}
