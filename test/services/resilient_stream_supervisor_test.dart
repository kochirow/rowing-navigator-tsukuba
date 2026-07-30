import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/resilient_stream_supervisor.dart';

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
  });
}
