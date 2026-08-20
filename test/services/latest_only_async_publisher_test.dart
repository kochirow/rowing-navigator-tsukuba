import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/latest_only_async_publisher.dart';

void main() {
  test('in-flight中の待機値は最新1件だけ送る', () async {
    final first = Completer<void>();
    final third = Completer<void>();
    final published = <int>[];
    final publisher = LatestOnlyAsyncPublisher<int>(
      publish: (value) {
        published.add(value);
        return switch (value) {
          1 => first.future,
          3 => third.future,
          _ => Future.value(),
        };
      },
    );

    publisher.start();
    publisher.add(1);
    publisher.add(2);
    publisher.add(3);
    await _pumpMicrotasks();

    expect(published, [1]);
    expect(publisher.hasInFlight, isTrue);
    expect(publisher.hasPending, isTrue);

    first.complete();
    await _pumpMicrotasks();
    expect(published, [1, 3]);

    third.complete();
    await _pumpMicrotasks();
    expect(publisher.hasInFlight, isFalse);
  });

  test('ACK timeoutで通知しても同時sendは1件のまま', () async {
    final first = Completer<void>();
    final published = <int>[];
    final timedOut = <int>[];
    final publisher = LatestOnlyAsyncPublisher<int>(
      publish: (value) {
        published.add(value);
        return first.future;
      },
      ackTimeout: Duration.zero,
      onAckTimeout: timedOut.add,
    );

    publisher.start();
    publisher.add(1);
    publisher.add(2);
    await _pumpMicrotasks();

    expect(timedOut, [1]);
    expect(published, [1]);

    first.complete();
    await _pumpMicrotasks();
    // 1の完了後にだけ次のsendが始まる。
    expect(published, [1, 2]);
    publisher.stop();
  });

  test('stopはpendingと古いcallbackを破棄する', () async {
    final first = Completer<void>();
    final published = <int>[];
    final succeeded = <int>[];
    final publisher = LatestOnlyAsyncPublisher<int>(
      publish: (value) {
        published.add(value);
        return first.future;
      },
      onSuccess: succeeded.add,
    );

    publisher.start();
    publisher.add(1);
    publisher.add(2);
    await _pumpMicrotasks();
    publisher.stop();
    first.complete();
    await _pumpMicrotasks();

    expect(published, [1]);
    expect(succeeded, isEmpty);
    expect(publisher.hasPending, isFalse);
    expect(publisher.isAccepting, isFalse);
  });

  test('失敗後はbackoff中に受けた最新値で再試行する', () async {
    final published = <int>[];
    final second = Completer<void>();
    final failures = <int>[];
    final publisher = LatestOnlyAsyncPublisher<int>(
      publish: (value) {
        published.add(value);
        if (published.length == 1) return Future.error(StateError('offline'));
        return second.future;
      },
      retryBackoff: const [Duration(milliseconds: 20)],
      onFailure: (value, _, __) => failures.add(value),
    );

    publisher.start();
    publisher.add(1);
    await _pumpMicrotasks();
    publisher.add(2);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await _pumpMicrotasks();

    expect(failures, [1]);
    expect(published, [1, 2]);
    second.complete();
    await _pumpMicrotasks();
  });

  test('前セッション完了後に新セッションの最新値を送る', () async {
    final oldWrite = Completer<void>();
    final newWrite = Completer<void>();
    final published = <int>[];
    final publisher = LatestOnlyAsyncPublisher<int>(
      publish: (value) {
        published.add(value);
        return value == 1 ? oldWrite.future : newWrite.future;
      },
    );

    publisher.start();
    publisher.add(1);
    await _pumpMicrotasks();
    publisher.stop();
    publisher.start();
    publisher.add(2);
    publisher.add(3);
    await _pumpMicrotasks();
    expect(published, [1]);

    oldWrite.complete();
    await _pumpMicrotasks();
    expect(published, [1, 3]);
    newWrite.complete();
    await _pumpMicrotasks();
  });

  test('遅延ACK後も最小間隔を空け、待機値は最新だけを送る', () async {
    final first = Completer<void>();
    final startedAt = <DateTime>[];
    final published = <int>[];
    const minimumInterval = Duration(milliseconds: 30);
    const clockTolerance = Duration(milliseconds: 1);
    final publisher = LatestOnlyAsyncPublisher<int>(
      publish: (value) {
        published.add(value);
        startedAt.add(DateTime.now());
        return value == 1 ? first.future : Future.value();
      },
      minPublishInterval: minimumInterval,
    );

    publisher.start();
    publisher.add(1);
    await _pumpMicrotasks();
    publisher.add(2);
    publisher.add(3);
    final firstCompletionSignaledAt = DateTime.now();
    first.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(published, [1]);

    await Future<void>.delayed(const Duration(milliseconds: 35));
    await _pumpMicrotasks();
    expect(published, [1, 3]);
    // 実装契約は「前回writeの完了から次の開始まで」。開始時刻同士を
    // 比べると、最初のwrite所要時間を含み、契約を検証できない。
    // DateTimeとStopwatchの読み取り差だけ1ms許容し、CIの境界揺れを除く。
    expect(
      startedAt[1].difference(firstCompletionSignaledAt),
      greaterThanOrEqualTo(minimumInterval - clockTolerance),
    );
    publisher.stop();
  });
}

Future<void> _pumpMicrotasks() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
