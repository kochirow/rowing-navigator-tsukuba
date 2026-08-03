import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/estimator_clock.dart';

void main() {
  test('予測時刻後も復旧fixをより新しい単調時刻に載せる', () {
    final clock = EstimatorClock();
    final origin = DateTime.utc(2026, 8, 3, 12);
    clock.resolve(fixTimestamp: origin, processElapsed: Duration.zero);
    final predicted =
        clock.resolvePrediction(const Duration(milliseconds: 3000));
    final recovered = clock.resolve(
      fixTimestamp: origin.add(const Duration(milliseconds: 2500)),
      processElapsed: const Duration(milliseconds: 3100),
    );

    expect(predicted, const Duration(milliseconds: 3000));
    expect(recovered, greaterThan(predicted));
  });

  final fixOrigin = DateTime.utc(2026, 7, 25, 6, 0, 0);

  group('EstimatorClock', () {
    test('処理遅延のジッタを dt から取り除き、測位間隔をそのまま渡す', () {
      final clock = EstimatorClock();
      // 測位は正確に1秒間隔。処理側は0〜400msの遅延ジッタを持つ。
      final jitterMs = [0, 380, 60, 250, 120];
      final resolved = <Duration>[];
      for (var index = 0; index < jitterMs.length; index++) {
        resolved.add(clock.resolve(
          fixTimestamp: fixOrigin.add(Duration(seconds: index)),
          processElapsed: Duration(
            milliseconds: index * 1000 + jitterMs[index],
          ),
        ));
      }

      // 初回は原点合わせのため処理時刻。以後はGNSS間隔がそのまま出る。
      for (var index = 1; index < resolved.length; index++) {
        final delta = resolved[index] - resolved[index - 1];
        expect(
          delta.inMilliseconds,
          closeTo(1000, index == 1 ? 400 : 1),
          reason: 'index $index',
        );
      }
    });

    test('測位間隔が不均一でも、その不均一さを保つ', () {
      final clock = EstimatorClock();
      clock.resolve(
        fixTimestamp: fixOrigin,
        processElapsed: Duration.zero,
      );
      final first = clock.resolve(
        fixTimestamp: fixOrigin.add(const Duration(milliseconds: 1500)),
        processElapsed: const Duration(milliseconds: 1600),
      );
      final second = clock.resolve(
        fixTimestamp: fixOrigin.add(const Duration(milliseconds: 2000)),
        processElapsed: const Duration(milliseconds: 2050),
      );

      expect(first.inMilliseconds, 1500);
      expect((second - first).inMilliseconds, 500);
    });

    test('端末時計が前方へ飛んだら処理時刻へ退避し、次のfixから復帰する', () {
      final clock = EstimatorClock();
      clock.resolve(fixTimestamp: fixOrigin, processElapsed: Duration.zero);
      clock.resolve(
        fixTimestamp: fixOrigin.add(const Duration(seconds: 1)),
        processElapsed: const Duration(seconds: 1),
      );

      // 時計が+1時間補正された。ドリフト上限(2秒)を超える。
      final jumped = clock.resolve(
        fixTimestamp: fixOrigin.add(const Duration(hours: 1, seconds: 2)),
        processElapsed: const Duration(seconds: 2),
      );
      expect(jumped, const Duration(seconds: 2));

      // 原点を取り直しているので、次のfixはGNSS間隔で継続する。
      final recovered = clock.resolve(
        fixTimestamp: fixOrigin.add(const Duration(hours: 1, seconds: 3)),
        processElapsed: const Duration(milliseconds: 3400),
      );
      expect(recovered, const Duration(seconds: 3));
    });

    test('時計が逆行しても単調性を保ち、測位を捨てさせない', () {
      final clock = EstimatorClock();
      clock.resolve(fixTimestamp: fixOrigin, processElapsed: Duration.zero);
      final second = clock.resolve(
        fixTimestamp: fixOrigin.add(const Duration(seconds: 1)),
        processElapsed: const Duration(seconds: 1),
      );
      final third = clock.resolve(
        fixTimestamp: fixOrigin.subtract(const Duration(seconds: 30)),
        processElapsed: const Duration(seconds: 2),
      );

      expect(third, greaterThan(second));
    });

    test('同一測位時刻が続いても厳密に増加させる', () {
      final clock = EstimatorClock();
      clock.resolve(fixTimestamp: fixOrigin, processElapsed: Duration.zero);
      final first = clock.resolve(
        fixTimestamp: fixOrigin.add(const Duration(seconds: 1)),
        processElapsed: const Duration(seconds: 1),
      );
      final repeated = clock.resolve(
        fixTimestamp: fixOrigin.add(const Duration(seconds: 1)),
        processElapsed: const Duration(seconds: 1),
      );

      expect(repeated, greaterThan(first));
    });

    test('resetで原点と単調性の基準を破棄する', () {
      final clock = EstimatorClock();
      clock.resolve(
        fixTimestamp: fixOrigin,
        processElapsed: const Duration(seconds: 5),
      );
      expect(clock.lastResolved, const Duration(seconds: 5));

      clock.reset();

      expect(clock.lastResolved, isNull);
      expect(clock.isTrackingGnssTimestamp, isFalse);
      expect(
        clock.resolve(
          fixTimestamp: fixOrigin,
          processElapsed: Duration.zero,
        ),
        Duration.zero,
      );
    });

    test('GNSS時刻を使わない設定では常に処理時刻を返す', () {
      final clock = EstimatorClock(useGnssTimestamp: false);
      clock.resolve(fixTimestamp: fixOrigin, processElapsed: Duration.zero);
      final resolved = clock.resolve(
        fixTimestamp: fixOrigin.add(const Duration(seconds: 1)),
        processElapsed: const Duration(milliseconds: 1400),
      );
      expect(resolved, const Duration(milliseconds: 1400));
    });
  });
}
