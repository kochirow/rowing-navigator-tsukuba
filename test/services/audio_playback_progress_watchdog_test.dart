import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/audio_playback_progress_watchdog.dart';

void main() {
  test('再生位置が進んでいる間は停止と判定しない', () {
    final watchdog = AudioPlaybackProgressWatchdog();
    final start = DateTime(2026, 7, 25, 12);

    watchdog.start(start);
    watchdog.recordProgress(
      const Duration(milliseconds: 500),
      start.add(const Duration(seconds: 2)),
    );

    expect(
      watchdog.isStalled(start.add(const Duration(seconds: 4))),
      isFalse,
    );
  });

  test('再生中表示でも位置が3秒進まなければ停止と判定する', () {
    final watchdog = AudioPlaybackProgressWatchdog();
    final start = DateTime(2026, 7, 25, 12);

    watchdog.start(start);
    watchdog.recordProgress(Duration.zero, start);
    watchdog.recordProgress(
      Duration.zero,
      start.add(const Duration(seconds: 2)),
    );

    expect(
      watchdog.isStalled(start.add(const Duration(seconds: 3))),
      isTrue,
    );
  });

  test('ループ終端で位置が戻っても再生進行として扱う', () {
    final watchdog = AudioPlaybackProgressWatchdog();
    final start = DateTime(2026, 7, 25, 12);

    watchdog.start(start);
    watchdog.recordProgress(const Duration(seconds: 4), start);
    watchdog.recordProgress(
      Duration.zero,
      start.add(const Duration(seconds: 2)),
    );

    expect(
      watchdog.isStalled(start.add(const Duration(seconds: 4))),
      isFalse,
    );
  });

  test('0.89秒の自前ループ完了は停止ではなく次周の開始として扱う', () {
    final watchdog = AudioPlaybackProgressWatchdog();
    final start = DateTime(2026, 7, 28, 12);

    watchdog.start(start);
    // ReleaseMode.loopではなく、onPlayerCompleteごとのseek(0)+resumeで
    // アプリが次周を開始する。completedそのものは故障ではない。
    for (var cycle = 1; cycle <= 4; cycle++) {
      final completedAt = start.add(Duration(milliseconds: cycle * 890));
      watchdog.recordProgress(const Duration(milliseconds: 890), completedAt);
      watchdog.recordLoopRestart(completedAt);
      expect(
        watchdog.isStalled(completedAt.add(const Duration(seconds: 2))),
        isFalse,
      );
    }
  });
}
