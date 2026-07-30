import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/hooks/use_alert.dart';

void main() {
  test('待機中のstopは後続のplayとrecoverに追い出されない', () async {
    final queue = AlertCommandQueue();
    final runningStarted = Completer<void>();
    final releaseRunning = Completer<void>();
    final order = <String>[];

    unawaited(queue.enqueue(AlertCommandKind.play, () async {
      order.add('running-play');
      runningStarted.complete();
      await releaseRunning.future;
    }));
    await runningStarted.future;

    final stop = queue.enqueue(AlertCommandKind.stop, () async {
      order.add('stop');
    });
    // stopが待っているのでrecoverは実行されない。次のplayはstopの後へ積まれる。
    final recover = queue.enqueue(AlertCommandKind.recover, () async {
      order.add('recover');
    });
    final nextPlay = queue.enqueue(AlertCommandKind.play, () async {
      order.add('next-play');
    });

    releaseRunning.complete();
    await Future.wait(<Future<void>>[stop, recover, nextPlay]);

    expect(order, <String>['running-play', 'stop', 'next-play']);
  });

  test('待機中のplayは最新の1件だけを実行する', () async {
    final queue = AlertCommandQueue();
    final runningStarted = Completer<void>();
    final releaseRunning = Completer<void>();
    final order = <String>[];

    unawaited(queue.enqueue(AlertCommandKind.play, () async {
      runningStarted.complete();
      await releaseRunning.future;
    }));
    await runningStarted.future;

    final oldPlay = queue.enqueue(AlertCommandKind.play, () async {
      order.add('old-play');
    });
    final latestPlay = queue.enqueue(AlertCommandKind.play, () async {
      order.add('latest-play');
    });

    releaseRunning.complete();
    await Future.wait(<Future<void>>[oldPlay, latestPlay]);

    expect(order, <String>['latest-play']);
  });

  test('空のキューではrecoverを実行する', () async {
    final queue = AlertCommandQueue();
    var recovered = false;

    await queue.enqueue(AlertCommandKind.recover, () async {
      recovered = true;
    });

    expect(recovered, isTrue);
  });
}
