import 'dart:math';

import '../config/log_config.dart';
import '../config/rowing_pace_config.dart';
import '../models/session_model.dart';

class PaceTrendPoint {
  final DateTime t;
  final double paceSecPer500;

  const PaceTrendPoint({required this.t, required this.paceSecPer500});
}

class AlertEpisode {
  final String id;
  final String alertId;
  final String category;
  final DateTime startedAt;
  final DateTime endedAt;
  final int maxRiskLevel;
  final bool hadCurrentOverlap;
  final double? minimumDistanceMeters;

  const AlertEpisode({
    required this.id,
    required this.alertId,
    required this.category,
    required this.startedAt,
    required this.endedAt,
    required this.maxRiskLevel,
    required this.hadCurrentOverlap,
    required this.minimumDistanceMeters,
  });

  double get durationSec => endedAt.difference(startedAt).inMilliseconds / 1000;
}

/// 練習セッションの解析(サマリー計算)。
/// 純粋なDartロジックのみで構成されており、単体テスト可能。
class SessionAnalyzerService {
  /// 2点間距離 [m](ハバサイン公式)
  static double distanceMeters(
      double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLng = (lng2 - lng1) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) *
            cos(lat2 * pi / 180) *
            sin(dLng / 2) *
            sin(dLng / 2);
    return 2 * r * atan2(sqrt(a), sqrt(1 - a));
  }

  /// 記録点列からサマリーを計算する
  SessionSummary analyze(
    List<TrackPoint> points, {
    String boatTypeName = '',
  }) {
    if (points.length < 2) {
      return SessionSummary(
        totalDistanceMeters: 0,
        durationSec: 0,
        maxSpeed: 0,
        avgSpeed: 0,
        movingTimeSec: 0,
        restTimeSec: 0,
        splits250: const [],
        splits: const [],
        pieces: const [],
        alertCounts: const {},
      );
    }

    double totalDistance = 0;
    double maxSpeed = 0;
    double movingTimeSec = 0;
    double restTimeSec = 0;
    double workDistance = 0;
    final alertCounts = <String, int>{};
    final splits250 = <Split>[];
    final splits = <Split>[];
    double split250Distance = 0;
    double split250Time = 0;
    double splitDistance = 0;
    double splitTime = 0;

    for (int i = 1; i < points.length; i++) {
      final prev = points[i - 1];
      final cur = points[i];
      final dtSec = cur.t.difference(prev.t).inMilliseconds / 1000.0;
      if (dtSec <= 0) continue;

      if (cur.speed > maxSpeed) maxSpeed = cur.speed;
      if (cur.safetyLevel != 'safe') {
        alertCounts[cur.safetyLevel] = (alertCounts[cur.safetyLevel] ?? 0) + 1;
      }

      // 停止中のGPSノイズは距離に含めない。
      if (cur.speed < distanceAccumulationMinSpeed) {
        restTimeSec += dtSec;
        continue;
      }

      final d = distanceMeters(prev.lat, prev.lng, cur.lat, cur.lng);
      totalDistance += d;

      // ワーク時間は500m=4:00より速い区間だけ。ゆっくり漕いでいる
      // 時間も、停止と同様に休憩時間へ入れる。
      if (cur.speed > RowingPaceProfile.minimumWorkSpeedMps) {
        workDistance += d;
        movingTimeSec += dtSec;
      } else {
        restTimeSec += dtSec;
      }

      // 250m区間
      split250Distance += d;
      split250Time += dtSec;
      if (split250Distance >= 250) {
        splits250.add(Split(
          index: splits250.length + 1,
          distanceMeters: split250Distance,
          timeSec: split250Time,
        ));
        split250Distance = 0;
        split250Time = 0;
      }

      // 500mスプリット
      splitDistance += d;
      splitTime += dtSec;
      if (splitDistance >= splitDistanceMeters) {
        splits.add(Split(
          index: splits.length + 1,
          distanceMeters: splitDistance,
          timeSec: splitTime,
        ));
        splitDistance = 0;
        splitTime = 0;
      }
    }
    // 250mの端数区間は50m以上なら残す。
    if (split250Distance >= 50) {
      splits250.add(Split(
        index: splits250.length + 1,
        distanceMeters: split250Distance,
        timeSec: split250Time,
      ));
    }
    // 端数のスプリット(100m以上あれば記録)
    if (splitDistance >= 100) {
      splits.add(Split(
        index: splits.length + 1,
        distanceMeters: splitDistance,
        timeSec: splitTime,
      ));
    }

    final durationSec =
        points.last.t.difference(points.first.t).inMilliseconds / 1000.0;
    final avgSpeed = movingTimeSec > 0 ? workDistance / movingTimeSec : 0.0;

    return SessionSummary(
      totalDistanceMeters: totalDistance,
      durationSec: durationSec,
      maxSpeed: maxSpeed,
      avgSpeed: avgSpeed,
      movingTimeSec: movingTimeSec,
      restTimeSec: restTimeSec,
      splits250: splits250,
      splits: splits,
      pieces: detectPieces(points, boatTypeName: boatTypeName),
      alertCounts: alertCounts,
    );
  }

  /// 15秒窓の距離から5秒ごとに算出するペース推移。
  ///
  /// 瞬間speedを直接500m換算せず、GNSSの1点ノイズをならして表示する。
  List<PaceTrendPoint> buildPaceTrend(
    List<TrackPoint> points, {
    Duration window = const Duration(seconds: 15),
    Duration sampleInterval = const Duration(seconds: 5),
    double? maximumPaceSecPer500,
  }) {
    if (points.length < 2) return const [];
    final result = <PaceTrendPoint>[];
    var windowStart = 0;
    DateTime? lastSampleAt;

    for (var end = 1; end < points.length; end++) {
      final endPoint = points[end];
      if (lastSampleAt != null &&
          endPoint.t.difference(lastSampleAt) < sampleInterval) {
        continue;
      }
      while (windowStart + 1 < end &&
          endPoint.t.difference(points[windowStart].t) > window) {
        windowStart += 1;
      }

      var distance = 0.0;
      var movingTime = 0.0;
      for (var index = windowStart + 1; index <= end; index++) {
        final current = points[index];
        final previous = points[index - 1];
        final dt = current.t.difference(previous.t).inMilliseconds / 1000.0;
        if (dt <= 0 || current.speed < distanceAccumulationMinSpeed) continue;
        distance += distanceMeters(
          previous.lat,
          previous.lng,
          current.lat,
          current.lng,
        );
        movingTime += dt;
      }
      if (distance < 10 || movingTime <= 0) continue;
      final paceSecPer500 = movingTime * 500 / distance;
      // 「より速い」指定なので、境界値そのものは表示しない。
      if (maximumPaceSecPer500 != null &&
          paceSecPer500 >= maximumPaceSecPer500) {
        continue;
      }
      result.add(PaceTrendPoint(
        t: endPoint.t,
        paceSecPer500: paceSecPer500,
      ));
      lastSampleAt = endPoint.t;
    }
    return List.unmodifiable(result);
  }

  /// 1Hzで記録された警告状態を、利用者が評価できる連続エピソードへ束ねる。
  List<AlertEpisode> detectAlertEpisodes(
    List<AlertDiagnosticEvent> events, {
    Duration maximumGap = const Duration(seconds: 3),
  }) {
    final observations = events
        .where((event) =>
            event.event == 'observation' &&
            (event.phase == 'alerting' || event.phase == 'clearing'))
        .toList()
      ..sort((a, b) => a.t.compareTo(b.t));
    if (observations.isEmpty) return const [];

    final builders = <_AlertEpisodeBuilder>[];
    final activeByAlertId = <String, _AlertEpisodeBuilder>{};
    for (final event in observations) {
      var builder = activeByAlertId[event.alertId];
      if (builder == null || event.t.difference(builder.endedAt) > maximumGap) {
        builder = _AlertEpisodeBuilder(event);
        builders.add(builder);
        activeByAlertId[event.alertId] = builder;
      } else {
        builder.add(event);
      }
    }
    return List.unmodifiable(builders.map((builder) => builder.build()));
  }

  /// 警告時刻に最も近い航跡点。時刻で関連付けるため座標の複製を避ける。
  TrackPoint? nearestTrackPoint(
    List<TrackPoint> points,
    DateTime time,
  ) {
    if (points.isEmpty) return null;
    var nearest = points.first;
    var nearestDifference = nearest.t.difference(time).inMilliseconds.abs();
    for (final point in points.skip(1)) {
      final difference = point.t.difference(time).inMilliseconds.abs();
      if (difference < nearestDifference) {
        nearest = point;
        nearestDifference = difference;
      }
    }
    return nearest;
  }

  /// 自動ピース検出:
  /// 艇種別の表示ペースより速い区間を、15秒の平均艇速で抽出する。
  ///
  /// 艇速はストロークごとに揺れるため、短い低下は同一ピースの中に残す。
  /// 休憩として明確な15秒超の途切れだけで分割する。
  List<Piece> detectPieces(
    List<TrackPoint> points, {
    String boatTypeName = '',
  }) {
    if (points.length < 2) return const [];
    final profile = RowingPaceProfile.forBoatTypeName(boatTypeName);
    final pieces = <Piece>[];
    int? segStart; // 現在のピースの開始インデックス
    int? lastFast; // 最後に高速だったインデックス

    void closeSegment(int endIndex) {
      if (segStart == null) return;
      final start = segStart!;
      final durationSec =
          points[endIndex].t.difference(points[start].t).inMilliseconds /
              1000.0;
      if (durationSec >= pieceMinDurationSec) {
        double dist = 0;
        double maxSpd = 0;
        double spmSum = 0;
        int spmCount = 0;
        for (int i = start + 1; i <= endIndex; i++) {
          dist += distanceMeters(points[i - 1].lat, points[i - 1].lng,
              points[i].lat, points[i].lng);
          if (points[i].speed > maxSpd) maxSpd = points[i].speed;
          final spm = points[i].spm;
          if (spm != null && spm > 0) {
            spmSum += spm;
            spmCount++;
          }
        }
        if (dist >= pieceMinDistanceMeters) {
          pieces.add(Piece(
            startTime: points[start].t,
            endTime: points[endIndex].t,
            distanceMeters: dist,
            durationSec: durationSec,
            maxSpeed: maxSpd,
            avgSpm: spmCount > 0 ? spmSum / spmCount : null,
          ));
        }
      }
      segStart = null;
      lastFast = null;
    }

    for (int i = 0; i < points.length; i++) {
      // 窓平均は減速の判定を安定させる。再加速は現在値も見ることで、
      // 短いレート調整の後に平均値が戻るまでの遅れで分割しない。
      final fast = points[i].speed > profile.minimumDisplaySpeedMps ||
          _smoothedSpeedAt(points, i) > profile.minimumDisplaySpeedMps;
      if (fast) {
        segStart ??= i;
        lastFast = i;
      } else if (segStart != null && lastFast != null) {
        final gapSec =
            points[i].t.difference(points[lastFast!].t).inMilliseconds / 1000.0;
        if (gapSec > pieceMaxGapSec) {
          closeSegment(lastFast!);
        }
      }
    }
    if (segStart != null && lastFast != null) {
      closeSegment(lastFast!);
    }
    return pieces;
  }

  double _smoothedSpeedAt(List<TrackPoint> points, int endIndex) {
    var weightedSpeed = 0.0;
    var elapsedSec = 0.0;
    final endTime = points[endIndex].t;
    for (var index = endIndex; index > 0; index--) {
      final current = points[index];
      final previous = points[index - 1];
      final dt = current.t.difference(previous.t).inMilliseconds / 1000.0;
      if (dt <= 0) continue;
      if (endTime.difference(previous.t).inSeconds >
          pieceSpeedSmoothingWindowSec) {
        break;
      }
      weightedSpeed += current.speed * dt;
      elapsedSec += dt;
    }
    // 窓を満たす前の発艇直後は、その時点のフィルター済み速度を使う。
    return elapsedSec > 0 ? weightedSpeed / elapsedSec : points[endIndex].speed;
  }
}

class _AlertEpisodeBuilder {
  final String alertId;
  final String category;
  final DateTime startedAt;
  DateTime endedAt;
  int maxRiskLevel;
  bool hadCurrentOverlap;
  double? minimumDistanceMeters;

  _AlertEpisodeBuilder(AlertDiagnosticEvent event)
      : alertId = event.alertId,
        category = event.category,
        startedAt = event.t,
        endedAt = event.t,
        maxRiskLevel = event.riskLevel,
        hadCurrentOverlap = event.currentOverlap,
        minimumDistanceMeters = event.distanceMeters;

  void add(AlertDiagnosticEvent event) {
    endedAt = event.t;
    if (event.riskLevel > maxRiskLevel) maxRiskLevel = event.riskLevel;
    hadCurrentOverlap = hadCurrentOverlap || event.currentOverlap;
    final distance = event.distanceMeters;
    if (distance != null &&
        (minimumDistanceMeters == null || distance < minimumDistanceMeters!)) {
      minimumDistanceMeters = distance;
    }
  }

  AlertEpisode build() => AlertEpisode(
        id: '${Uri.encodeComponent(alertId)}@'
            '${startedAt.millisecondsSinceEpoch}',
        alertId: alertId,
        category: category,
        startedAt: startedAt,
        endedAt: endedAt,
        maxRiskLevel: maxRiskLevel,
        hadCurrentOverlap: hadCurrentOverlap,
        minimumDistanceMeters: minimumDistanceMeters,
      );
}
