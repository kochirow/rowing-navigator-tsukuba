import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/session_model.dart';
import 'package:rowing_navigator/services/session_aggregator.dart';

void main() {
  Session session({
    required String id,
    required DateTime startedAt,
    double distance = 1000,
    double duration = 600,
    double avgSpeed = 2.5,
    bool isComplete = true,
  }) {
    return Session(
      id: id,
      startedAt: startedAt,
      endedAt: startedAt.add(Duration(seconds: duration.round())),
      boatTypeName: '1x',
      seatPosLabel: 'ストローク',
      points: const [],
      summary: SessionSummary(
        totalDistanceMeters: distance,
        durationSec: duration,
        maxSpeed: avgSpeed,
        avgSpeed: avgSpeed,
        splits: const [],
        pieces: const [],
        alertCounts: const {},
      ),
      isComplete: isComplete,
    );
  }

  test('空の入力はゼロ集計になる', () {
    final result = SessionAggregator.aggregate(
      const [],
      period: SessionAggregationPeriod.all,
    );

    expect(result.sessionCount, 0);
    expect(result.totalDistanceMeters, 0);
    expect(result.totalDurationSec, 0);
    expect(result.avgPaceSecPer500, 0);
  });

  test('今週はローカル時刻の月曜から翌月曜直前まで', () {
    final result = SessionAggregator.aggregate(
      [
        session(id: 'sun', startedAt: DateTime(2026, 7, 19, 23, 59)),
        session(id: 'mon', startedAt: DateTime(2026, 7, 20)),
        session(id: 'next', startedAt: DateTime(2026, 7, 27)),
      ],
      period: SessionAggregationPeriod.thisWeek,
      now: DateTime(2026, 7, 22, 12),
    );

    expect(result.sessions.map((value) => value.id), ['mon']);
  });

  test('今月は暦月の開始以上・翌月開始未満', () {
    final result = SessionAggregator.aggregate(
      [
        session(id: 'june', startedAt: DateTime(2026, 6, 30, 23, 59)),
        session(id: 'july', startedAt: DateTime(2026, 7, 1)),
        session(id: 'august', startedAt: DateTime(2026, 8, 1)),
      ],
      period: SessionAggregationPeriod.thisMonth,
      now: DateTime(2026, 7, 22),
    );

    expect(result.sessions.map((value) => value.id), ['july']);
  });

  test('平均ペースは移動時間による距離加重で算出する', () {
    final result = SessionAggregator.aggregate(
      [
        session(
          id: 'fast',
          startedAt: DateTime(2026, 7, 1),
          distance: 500,
          avgSpeed: 5,
        ),
        session(
          id: 'steady',
          startedAt: DateTime(2026, 7, 2),
          distance: 1500,
          avgSpeed: 2.5,
        ),
      ],
      period: SessionAggregationPeriod.all,
    );

    expect(result.totalDistanceMeters, 2000);
    expect(result.avgPaceSecPer500, closeTo(175, 0.001));
  });

  test('ワーク時間がある記録は休憩中の移動距離を平均ペースへ含めない', () {
    final first = session(
      id: 'work-and-rest',
      startedAt: DateTime(2026, 7, 1),
      distance: 400,
      avgSpeed: 2,
    ).copyWith(
      summary: SessionSummary(
        totalDistanceMeters: 400,
        durationSec: 200,
        maxSpeed: 2.5,
        avgSpeed: 2,
        movingTimeSec: 100,
        restTimeSec: 100,
        splits: const [],
        pieces: const [],
        alertCounts: const {},
      ),
    );
    final second = session(
      id: 'all-work',
      startedAt: DateTime(2026, 7, 2),
      distance: 500,
      avgSpeed: 5,
    ).copyWith(
      summary: SessionSummary(
        totalDistanceMeters: 500,
        durationSec: 100,
        maxSpeed: 5,
        avgSpeed: 5,
        movingTimeSec: 100,
        splits: const [],
        pieces: const [],
        alertCounts: const {},
      ),
    );

    final result = SessionAggregator.aggregate(
      [first, second],
      period: SessionAggregationPeriod.all,
    );

    expect(result.avgPaceSecPer500, closeTo(200 * 500 / 700, 0.001));
  });

  test('復旧セッションも既定で含め、明示時だけ除外する', () {
    final recovered = session(
      id: 'recovered',
      startedAt: DateTime(2026, 7, 1),
      isComplete: false,
    );

    expect(
      SessionAggregator.aggregate(
        [recovered],
        period: SessionAggregationPeriod.all,
      ).sessionCount,
      1,
    );
    expect(
      SessionAggregator.aggregate(
        [recovered],
        period: SessionAggregationPeriod.all,
        includeIncomplete: false,
      ).sessionCount,
      0,
    );
  });

  test('距離ゼロは本数と時間に含めるが平均ペースには含めない', () {
    final result = SessionAggregator.aggregate(
      [
        session(
          id: 'zero',
          startedAt: DateTime(2026, 7, 1),
          distance: 0,
          duration: 120,
          avgSpeed: 0,
        ),
      ],
      period: SessionAggregationPeriod.all,
    );

    expect(result.sessionCount, 1);
    expect(result.totalDurationSec, 120);
    expect(result.avgPaceSecPer500, 0);
  });
}
