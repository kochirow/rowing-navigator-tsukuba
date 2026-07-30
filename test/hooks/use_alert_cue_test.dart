import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/hooks/use_alert.dart';

void main() {
  group('AlertCueQueue', () {
    test('同じeventIdは二度積まない', () {
      final queue = AlertCueQueue();

      final first =
          queue.admit(AlertCueRequest('audio/curve_warning.mp3', 'curve-1'));
      final second =
          queue.admit(AlertCueRequest('audio/curve_warning.mp3', 'curve-1'));

      expect(first.accepted, isTrue);
      expect(second.accepted, isFalse);
      expect(second.rejectReason, 'duplicate_event_id');
      expect(queue.pending, hasLength(1));
    });

    test('アセットが同じでもeventIdが違えば別の合図として積む', () {
      final queue = AlertCueQueue();

      queue.admit(AlertCueRequest('audio/curve_warning.mp3', 'curve-1'));
      final second =
          queue.admit(AlertCueRequest('audio/curve_warning.mp3', 'curve-2'));

      expect(second.accepted, isTrue);
      expect(queue.pending.map((r) => r.eventId), ['curve-1', 'curve-2']);
    });

    test('FIFOで取り出す', () {
      final queue = AlertCueQueue();
      queue.admit(AlertCueRequest('audio/bridge_warning.mp3', 'bridge-1'));
      queue.admit(AlertCueRequest('audio/curve_warning.mp3', 'curve-1'));

      expect(queue.takeNext()?.eventId, 'bridge-1');
      expect(queue.takeNext()?.eventId, 'curve-1');
      expect(queue.takeNext(), isNull);
      expect(queue.hasPending, isFalse);
    });

    test('上限を超えた分は古いものから捨て、捨てた要求を返す', () {
      final queue = AlertCueQueue(maxPending: 2);

      queue.admit(AlertCueRequest('audio/curve_warning.mp3', 'cue-1'));
      queue.admit(AlertCueRequest('audio/curve_warning.mp3', 'cue-2'));
      final third =
          queue.admit(AlertCueRequest('audio/curve_warning.mp3', 'cue-3'));

      expect(third.accepted, isTrue);
      // 黙って落とさず、呼出側が診断へ出せるよう返す。
      expect(third.dropped.map((r) => r.eventId), ['cue-1']);
      expect(queue.pending.map((r) => r.eventId), ['cue-2', 'cue-3']);
    });

    test('捨てられた要求の待ち手も完了させられる', () async {
      final queue = AlertCueQueue(maxPending: 1);
      final dropped = AlertCueRequest('audio/curve_warning.mp3', 'cue-1');
      queue.admit(dropped);

      final admission =
          queue.admit(AlertCueRequest('audio/curve_warning.mp3', 'cue-2'));
      for (final request in admission.dropped) {
        request.complete();
      }

      await expectLater(dropped.done, completes);
    });

    test('重複排除の記憶は上限を超えると古いものから捨てる', () {
      final queue = AlertCueQueue(maxPending: 64, playedEventIdLimit: 2);

      queue.admit(AlertCueRequest('audio/curve_warning.mp3', 'cue-1'));
      queue.admit(AlertCueRequest('audio/curve_warning.mp3', 'cue-2'));
      queue.admit(AlertCueRequest('audio/curve_warning.mp3', 'cue-3'));

      // cue-1 は記憶から溢れているので、再度積める。
      expect(
        queue
            .admit(AlertCueRequest('audio/curve_warning.mp3', 'cue-1'))
            .accepted,
        isTrue,
      );
      // 直近の cue-3 は記憶に残っているので二度鳴らさない。
      expect(
        queue
            .admit(AlertCueRequest('audio/curve_warning.mp3', 'cue-3'))
            .accepted,
        isFalse,
      );
    });

    test('停止時のtakeAllは重複排除の記憶を消さない', () {
      final queue = AlertCueQueue();
      queue.admit(AlertCueRequest('audio/curve_warning.mp3', 'cue-1'));

      expect(queue.takeAll().map((r) => r.eventId), ['cue-1']);
      expect(queue.hasPending, isFalse);
      // 停止をまたいで同じ合図が鳴り直さない。
      expect(
        queue
            .admit(AlertCueRequest('audio/curve_warning.mp3', 'cue-1'))
            .accepted,
        isFalse,
      );
    });

    test('resetは記憶ごと初期化する', () {
      final queue = AlertCueQueue();
      queue.admit(AlertCueRequest('audio/curve_warning.mp3', 'cue-1'));

      queue.reset();

      expect(queue.hasPending, isFalse);
      expect(
        queue
            .admit(AlertCueRequest('audio/curve_warning.mp3', 'cue-1'))
            .accepted,
        isTrue,
      );
    });
  });
}
