import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/resilient_stream_supervisor.dart';

class _ManualStream<T> extends Stream<T> {
  void Function(T value)? _onData;
  void Function(Object error, StackTrace stackTrace)? _onError;

  void add(T value) => _onData?.call(value);

  void addError(Object error) => _onError?.call(error, StackTrace.current);

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _onData = onData;
    _onError = (error, stackTrace) {
      if (onError != null) onError(error, stackTrace);
    };
    return _UncancellableSubscription<T>();
  }
}

class _UncancellableSubscription<T> implements StreamSubscription<T> {
  @override
  Future<void> cancel() async {}

  @override
  void onData(void Function(T data)? handleData) {}

  @override
  void onDone(void Function()? handleDone) {}

  @override
  void onError(Function? handleError) {}

  @override
  void pause([Future<void>? resumeSignal]) {}

  @override
  void resume() {}

  @override
  bool get isPaused => false;

  @override
  Future<E> asFuture<E>([E? futureValue]) => Future<E>.value(futureValue as E);
}

void main() {
  group('ResilientStreamSupervisor', () {
    test('stream error後に再購読して次の値を届ける', () async {
      final controllers = <StreamController<int>>[];
      final received = <int>[];
      final recovered = Completer<void>();
      final supervisor = ResilientStreamSupervisor<int>(
        retryBackoff: const [Duration(milliseconds: 10)],
        silenceTimeout: const Duration(seconds: 1),
      );

      await supervisor.start(
        streamFactory: () {
          final controller = StreamController<int>();
          controllers.add(controller);
          return controller.stream;
        },
        onData: (value) {
          received.add(value);
          if (value == 2 && !recovered.isCompleted) recovered.complete();
        },
      );
      controllers.first.add(1);
      controllers.first.addError(StateError('temporary GPS error'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(controllers.length, 2);
      controllers.last.add(2);
      await recovered.future.timeout(const Duration(seconds: 1));

      expect(received, [1, 2]);
      await supervisor.stop();
      for (final controller in controllers) {
        await controller.close();
      }
    });

    test('無通知停止を検知して再購読する', () async {
      final controllers = <StreamController<int>>[];
      final supervisor = ResilientStreamSupervisor<int>(
        retryBackoff: const [Duration(milliseconds: 5)],
        silenceTimeout: const Duration(milliseconds: 15),
      );

      await supervisor.start(
        streamFactory: () {
          final controller = StreamController<int>();
          controllers.add(controller);
          return controller.stream;
        },
        onData: (_) {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(controllers.length, greaterThanOrEqualTo(2));
      await supervisor.stop();
      for (final controller in controllers) {
        await controller.close();
      }
    });

    test('解決関数が返した時間を無通知の判定に使う', () async {
      // 休憩中はOSが配信を絞る。そこへ短い閾値で購読を張り直すと、
      // 暖機を毎回捨てて自分で欠測を増やす(2026-08-05 実機ログ 251回)。
      final controllers = <StreamController<int>>[];
      var extended = true;
      final supervisor = ResilientStreamSupervisor<int>(
        retryBackoff: const [Duration(milliseconds: 5)],
        silenceTimeout: const Duration(milliseconds: 15),
        silenceTimeoutResolver: () =>
            extended ? const Duration(seconds: 5) : null,
      );

      await supervisor.start(
        streamFactory: () {
          final controller = StreamController<int>();
          controllers.add(controller);
          return controller.stream;
        },
        onData: (_) {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(controllers.length, 1, reason: '延長中は張り直さない');

      // 解決関数が null を返せば既定(15ms)へ戻る。
      extended = false;
      controllers.first.add(1);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(controllers.length, greaterThanOrEqualTo(2));

      await supervisor.stop();
      for (final controller in controllers) {
        await controller.close();
      }
    });

    test('解決関数が例外を投げても監視を止めない', () async {
      final controllers = <StreamController<int>>[];
      final supervisor = ResilientStreamSupervisor<int>(
        retryBackoff: const [Duration(milliseconds: 5)],
        silenceTimeout: const Duration(milliseconds: 15),
        silenceTimeoutResolver: () => throw StateError('boom'),
      );

      await supervisor.start(
        streamFactory: () {
          final controller = StreamController<int>();
          controllers.add(controller);
          return controller.stream;
        },
        onData: (_) {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(controllers.length, greaterThanOrEqualTo(2));

      await supervisor.stop();
      for (final controller in controllers) {
        await controller.close();
      }
    });

    test('stop後は再購読も古い値の通知もしない', () async {
      final controller = StreamController<int>();
      var factoryCalls = 0;
      var dataCalls = 0;
      final supervisor = ResilientStreamSupervisor<int>(
        retryBackoff: const [Duration(milliseconds: 5)],
        silenceTimeout: const Duration(milliseconds: 15),
      );

      await supervisor.start(
        streamFactory: () {
          factoryCalls += 1;
          return controller.stream;
        },
        onData: (_) => dataCalls += 1,
      );
      await supervisor.stop();
      controller.add(1);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(factoryCalls, 1);
      expect(dataCalls, 0);
      await controller.close();
    });

    test('再購読後はcancelできない古いstreamの値を無視する', () async {
      final streams = <_ManualStream<int>>[];
      final received = <int>[];
      final supervisor = ResilientStreamSupervisor<int>(
        retryBackoff: const [Duration(milliseconds: 5)],
      );

      await supervisor.start(
        streamFactory: () {
          final stream = _ManualStream<int>();
          streams.add(stream);
          return stream;
        },
        onData: received.add,
      );
      streams.first.add(1);
      streams.first.addError(StateError('reconnect'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(streams, hasLength(2));

      streams.first.add(99);
      streams.last.add(2);
      await Future<void>.delayed(Duration.zero);

      expect(received, [1, 2]);
      await supervisor.stop();
    });
  });
}
