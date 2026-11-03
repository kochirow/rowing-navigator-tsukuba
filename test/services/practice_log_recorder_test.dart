import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/message_model.dart';
import 'package:rowing_navigator/services/practice_log_recorder.dart';
import 'package:rowing_navigator/types/boat_type.dart';

Message message({required String session, required int sequence}) => Message(
      boatId: 'boat-a',
      displayName: 'A',
      sessionId: session,
      sequence: sequence,
      boatType: BoatType.r_1x,
      lat: 36,
      lng: 140,
      heading: 10,
      speed: 3,
      timestamp: DateTime.utc(2026, 7, 28),
      accuracy: 4,
    );

void main() {
  test('重複を除きseqの飛びとセッション交替を別イベントで残す', () {
    final start = DateTime.utc(2026, 7, 28, 5);
    final recorder = PracticeLogRecorder(startedAt: start);
    recorder.recordMessage(message(session: 'one', sequence: 1), now: start);
    recorder.recordMessage(message(session: 'one', sequence: 1),
        now: start.add(const Duration(seconds: 1)));
    recorder.recordMessage(message(session: 'one', sequence: 4),
        now: start.add(const Duration(seconds: 4)));
    recorder.recordMessage(message(session: 'two', sequence: 1),
        now: start.add(const Duration(seconds: 5)));
    final drained = recorder.drain();
    expect(drained.points, hasLength(3));
    expect(drained.events.map((e) => e.type),
        containsAll(['gap', 'boat_session_changed']));
  });

  test('TTL消失と監視端末側中断を別イベントで残す', () {
    final start = DateTime.utc(2026, 7, 28, 5);
    final recorder = PracticeLogRecorder(
        startedAt: start, lostAfter: const Duration(seconds: 10));
    recorder.recordMessage(message(session: 'one', sequence: 1), now: start);
    recorder.tick(start.add(const Duration(seconds: 11)));
    recorder.pause(start.add(const Duration(seconds: 12)), state: 'paused');
    recorder.resume(start.add(const Duration(seconds: 60)), state: 'resumed');
    expect(
        recorder.drain().events.map((e) => e.type),
        containsAll([
          'boat_lost',
          'recorder_paused',
          'recorder_resumed',
          'recorder_gap'
        ]));
  });

  group('背面の間の記録(R8-R6)', () {
    final start = DateTime.utc(2026, 11, 4, 6);
    DateTime at(int seconds) => start.add(Duration(seconds: seconds));

    test('背面でも10秒ごとに記録が動いていれば、中断とは書かない', () {
      final recorder = PracticeLogRecorder(startedAt: start);
      recorder.pause(at(0), state: 'paused');
      for (var s = 10; s <= 120; s += 10) {
        recorder.tick(at(s));
      }
      recorder.recordMessage(message(session: 'one', sequence: 1),
          now: at(125));
      recorder.resume(at(130), state: 'resumed');
      final events = recorder.drain().events;
      expect(events.map((e) => e.type), isNot(contains('recorder_gap')));
      final background =
          events.singleWhere((e) => e.type == 'recorder_background');
      expect(background.details['aliveCount'], 13);
      expect(background.details['suspendedCount'], 0);
      expect(background.details['maxSilenceSec'], 10);
    });

    test('背面の途中で処理が止まった区間だけを中断として書く', () {
      final recorder = PracticeLogRecorder(startedAt: start);
      recorder.pause(at(0), state: 'paused');
      recorder.tick(at(10));
      recorder.tick(at(20));
      // 20秒から200秒まで何も動かなかった(OSが止めた)。
      recorder.tick(at(200));
      recorder.resume(at(205), state: 'resumed');
      final events = recorder.drain().events;
      final gaps = events.where((e) => e.type == 'recorder_gap').toList();
      expect(gaps, hasLength(1));
      expect(gaps.single.details['from'], at(20).toIso8601String());
      expect(gaps.single.details['to'], at(200).toIso8601String());
      expect(gaps.single.details['reason'], 'app_background_suspended');
      final background =
          events.singleWhere((e) => e.type == 'recorder_background');
      expect(background.details['suspendedCount'], 1);
      expect(background.details['maxSilenceSec'], 180);
    });

    test('背面の間に印が1つも無く長ければ、全体を1つの中断として書く', () {
      final recorder = PracticeLogRecorder(startedAt: start);
      recorder.pause(at(0), state: 'paused');
      recorder.resume(at(90), state: 'resumed');
      final gap =
          recorder.drain().events.singleWhere((e) => e.type == 'recorder_gap');
      expect(gap.details['from'], at(0).toIso8601String());
      expect(gap.details['to'], at(90).toIso8601String());
      expect(gap.details['reason'], 'app_background');
    });

    test('短い背面(通知の確認など)は印が無くても中断にしない', () {
      final recorder = PracticeLogRecorder(startedAt: start);
      recorder.pause(at(0), state: 'hidden');
      recorder.resume(at(8), state: 'resumed');
      expect(recorder.drain().events.map((e) => e.type),
          isNot(contains('recorder_gap')));
    });
  });
}
