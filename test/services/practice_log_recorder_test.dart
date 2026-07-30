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
    recorder.resume(start.add(const Duration(seconds: 20)), state: 'resumed');
    expect(
        recorder.drain().events.map((e) => e.type),
        containsAll([
          'boat_lost',
          'recorder_paused',
          'recorder_resumed',
          'recorder_gap'
        ]));
  });
}
