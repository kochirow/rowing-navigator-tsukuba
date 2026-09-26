import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/lap_metrics_tracker.dart';

void main() {
  final t0 = DateTime(2026, 9, 26, 6);
  DateTime at(int s) => t0.add(Duration(seconds: s));

  test('chrono は漕いでいる間だけ積み、止まっている間と測位の空白は積まない', () {
    final tracker = LapMetricsTracker();
    var distance = 0.0;
    // 0〜60秒 漕ぐ(4m/s)
    for (var s = 0; s <= 60; s++) {
      tracker.onPosition(
          at: at(s), speedMetersPerSecond: 4, totalDistanceMeters: distance);
      distance += 4;
    }
    // 61〜90秒 止まる
    for (var s = 61; s <= 90; s++) {
      tracker.onPosition(
          at: at(s), speedMetersPerSecond: 0.1, totalDistanceMeters: distance);
    }
    // 30秒の測位の空白のあと、また漕ぐ(空白は数えない)
    for (var s = 120; s <= 150; s++) {
      tracker.onPosition(
          at: at(s), speedMetersPerSecond: 4, totalDistanceMeters: distance);
      distance += 4;
    }
    expect(tracker.lapRowingSeconds, 60 + 30);
    expect(tracker.lapDistanceMeters, (distance - 4).round());
  });

  test('RESET で表示は0から数え直し、元に戻すと戻る。本数は同じ区切りを2度数えない', () {
    final tracker = LapMetricsTracker();
    for (var s = 0; s <= 10; s++) {
      tracker.onPosition(
          at: at(s), speedMetersPerSecond: 4, totalDistanceMeters: s * 4.0);
      tracker.onStroke(at(s));
      tracker.onStroke(at(s)); // 同じ区切りが2度届いても1本
    }
    expect(tracker.lapStrokes, 11);
    expect(tracker.lapDistanceMeters, 40);

    tracker.reset();
    expect(tracker.lapDistanceMeters, 0);
    expect(tracker.lapRowingSeconds, 0);
    expect(tracker.lapStrokes, 0);

    for (var s = 11; s <= 15; s++) {
      tracker.onPosition(
          at: at(s), speedMetersPerSecond: 4, totalDistanceMeters: s * 4.0);
      tracker.onStroke(at(s));
    }
    expect(tracker.lapDistanceMeters, 20);
    expect(tracker.lapRowingSeconds, 5);
    expect(tracker.lapStrokes, 5);

    expect(tracker.undoReset(), isTrue);
    expect(tracker.lapDistanceMeters, 60);
    expect(tracker.lapStrokes, 16);
    expect(tracker.undoReset(), isFalse, reason: '元に戻すのは1回だけ');
  });
}
