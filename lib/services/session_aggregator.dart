import '../models/session_model.dart';

enum SessionAggregationPeriod { thisWeek, thisMonth, all }

/// 選択期間に含まれる練習記録の集計結果。
class SessionAggregate {
  final List<Session> sessions;
  final double totalDistanceMeters;
  final double totalDurationSec;
  final double avgPaceSecPer500;

  const SessionAggregate({
    required this.sessions,
    required this.totalDistanceMeters,
    required this.totalDurationSec,
    required this.avgPaceSecPer500,
  });

  int get sessionCount => sessions.length;
}

/// 端末内のセッションだけをO(n)で期間集計する純Dartサービス。
class SessionAggregator {
  const SessionAggregator._();

  static SessionAggregate aggregate(
    List<Session> sessions, {
    required SessionAggregationPeriod period,
    DateTime? now,
    bool includeIncomplete = true,
  }) {
    final localNow = (now ?? DateTime.now()).toLocal();
    final range = _rangeFor(period, localNow);
    final selected = <Session>[];
    var totalDistance = 0.0;
    var totalDuration = 0.0;
    var totalMovingTime = 0.0;
    var paceDistance = 0.0;

    for (final session in sessions) {
      if (!includeIncomplete && !session.isComplete) continue;
      final startedAt = session.startedAt.toLocal();
      if (range != null &&
          (startedAt.isBefore(range.start) || !startedAt.isBefore(range.end))) {
        continue;
      }

      selected.add(session);
      final summary = session.summary;
      if (summary.totalDistanceMeters.isFinite &&
          summary.totalDistanceMeters > 0) {
        totalDistance += summary.totalDistanceMeters;
      }
      if (summary.durationSec.isFinite && summary.durationSec > 0) {
        totalDuration += summary.durationSec;
      }

      // 平均ペースはワーク時間・ワーク距離の加重平均にする。
      // 新しい記録は avgSpeed × movingTimeSec でワーク距離を復元できる。
      // movingTimeSecのない旧記録だけは、従来の総距離から後方互換で復元する。
      if (summary.movingTimeSec.isFinite &&
          summary.movingTimeSec > 0 &&
          summary.avgSpeed.isFinite &&
          summary.avgSpeed > 0) {
        totalMovingTime += summary.movingTimeSec;
        paceDistance += summary.avgSpeed * summary.movingTimeSec;
      } else if (summary.totalDistanceMeters.isFinite &&
          summary.totalDistanceMeters > 0 &&
          summary.avgSpeed.isFinite &&
          summary.avgSpeed > 0) {
        totalMovingTime += summary.totalDistanceMeters / summary.avgSpeed;
        paceDistance += summary.totalDistanceMeters;
      }
    }

    final avgPace =
        paceDistance > 0 ? totalMovingTime * 500.0 / paceDistance : 0.0;
    return SessionAggregate(
      sessions: List.unmodifiable(selected),
      totalDistanceMeters: totalDistance,
      totalDurationSec: totalDuration,
      avgPaceSecPer500: avgPace,
    );
  }

  static ({DateTime start, DateTime end})? _rangeFor(
    SessionAggregationPeriod period,
    DateTime localNow,
  ) {
    switch (period) {
      case SessionAggregationPeriod.thisWeek:
        final today = DateTime(localNow.year, localNow.month, localNow.day);
        final start = today.subtract(Duration(days: today.weekday - 1));
        return (start: start, end: start.add(const Duration(days: 7)));
      case SessionAggregationPeriod.thisMonth:
        final start = DateTime(localNow.year, localNow.month);
        final end = DateTime(localNow.year, localNow.month + 1);
        return (start: start, end: end);
      case SessionAggregationPeriod.all:
        return null;
    }
  }
}
