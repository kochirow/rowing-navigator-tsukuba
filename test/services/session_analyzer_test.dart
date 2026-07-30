import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/session_model.dart';
import 'package:rowing_navigator/services/session_analyzer_service.dart';

/// 北向きに等速で進む記録点列を作る(緯度0.0000450度 ≒ 5m)
List<TrackPoint> makeStraightTrack({
  required int seconds,
  required double speedMps,
  double startLat = 36.0670,
  double startLng = 140.2045,
  DateTime? start,
  double? spm,
}) {
  final t0 = start ?? DateTime(2026, 7, 7, 6, 0, 0);
  const metersPerDegLat = 111320.0;
  return List.generate(seconds + 1, (i) {
    return TrackPoint(
      t: t0.add(Duration(seconds: i)),
      lat: startLat + (speedMps * i) / metersPerDegLat,
      lng: startLng,
      speed: speedMps,
      heading: 0,
      spm: spm,
      safetyLevel: 'safe',
    );
  });
}

void main() {
  final analyzer = SessionAnalyzerService();

  group('analyze', () {
    test('空の記録はゼロサマリー', () {
      final summary = analyzer.analyze([]);
      expect(summary.totalDistanceMeters, 0);
      expect(summary.durationSec, 0);
    });

    test('3m/sで500秒進むと約1500m', () {
      final points = makeStraightTrack(seconds: 500, speedMps: 3.0);
      final summary = analyzer.analyze(points);
      expect(summary.totalDistanceMeters, greaterThan(1450));
      expect(summary.totalDistanceMeters, lessThan(1550));
      expect(summary.durationSec, 500);
      expect(summary.maxSpeed, 3.0);
      // 500mスプリットが約3本できる
      expect(summary.splits.length, inInclusiveRange(2, 4));
    });

    test('停止中のGPSノイズは距離に含めない', () {
      final t0 = DateTime(2026, 7, 7, 6, 0, 0);
      // 速度0でわずかに位置が揺れる記録
      final points = List.generate(60, (i) {
        return TrackPoint(
          t: t0.add(Duration(seconds: i)),
          lat: 36.0670 + (i % 2) * 0.00002,
          lng: 140.2045,
          speed: 0.0,
          heading: 0,
          safetyLevel: 'safe',
        );
      });
      final summary = analyzer.analyze(points);
      expect(summary.totalDistanceMeters, 0);
      expect(summary.movingTimeSec, 0);
      expect(summary.restTimeSec, closeTo(59, 0.1));
    });

    test('移動・休憩時間と250m・500m区間を分ける', () {
      final points = makeStraightTrack(seconds: 200, speedMps: 3);
      final summary = analyzer.analyze(points);

      expect(summary.movingTimeSec, closeTo(200, 0.1));
      expect(summary.restTimeSec, 0);
      expect(summary.splits250.length, inInclusiveRange(2, 3));
      expect(summary.splits.length, inInclusiveRange(1, 2));
    });

    test('ワーク時間は500m=4:00より速い区間だけを数える', () {
      final t0 = DateTime(2026, 7, 7, 6, 0, 0);
      final points = <TrackPoint>[
        ...makeStraightTrack(seconds: 60, speedMps: 2.2, start: t0),
        ...makeStraightTrack(
          seconds: 60,
          speedMps: 2.0,
          start: t0.add(const Duration(seconds: 61)),
        ),
      ];

      final summary = analyzer.analyze(points);

      expect(summary.movingTimeSec, closeTo(60, 1));
      expect(summary.restTimeSec, closeTo(61, 1));
    });

    test('ペース推移は移動窓で有限値を返す', () {
      final points = makeStraightTrack(seconds: 60, speedMps: 2.5);
      final trend = analyzer.buildPaceTrend(points);

      expect(trend, isNotEmpty);
      expect(trend.every((point) => point.paceSecPer500.isFinite), isTrue);
      expect(trend.last.paceSecPer500, closeTo(200, 5));
    });

    test('ペース推移は艇種の表示基準より遅い値を除外する', () {
      final points = makeStraightTrack(seconds: 60, speedMps: 2.5);

      final oneX = analyzer.buildPaceTrend(
        points,
        maximumPaceSecPer500: 225,
      );
      final twoX = analyzer.buildPaceTrend(
        points,
        maximumPaceSecPer500: 195,
      );

      expect(oneX, isNotEmpty); // 3:20 /500m は1xの3:45より速い。
      expect(twoX, isEmpty); // 3:20 /500m は2xの3:15より速くない。
    });
  });

  group('detectPieces (自動ピース検出)', () {
    test('漕いだ区間を1本のピースとして検出する', () {
      final t0 = DateTime(2026, 7, 7, 6, 0, 0);
      final points = <TrackPoint>[
        // 停止60秒
        ...makeStraightTrack(seconds: 59, speedMps: 0.0, start: t0),
        // 3.5m/sで120秒(ピース)
        ...makeStraightTrack(
            seconds: 120,
            speedMps: 3.5,
            start: t0.add(const Duration(seconds: 60)),
            spm: 24),
        // 停止60秒
        ...makeStraightTrack(
            seconds: 59,
            speedMps: 0.0,
            start: t0.add(const Duration(seconds: 181))),
      ];
      final pieces = analyzer.detectPieces(points);
      expect(pieces.length, 1);
      expect(pieces.first.durationSec, greaterThanOrEqualTo(100));
      expect(pieces.first.avgSpm, isNotNull);
      expect(pieces.first.avgSpm!, closeTo(24, 1));
    });

    test('短すぎる高速区間はピースにしない', () {
      final t0 = DateTime(2026, 7, 7, 6, 0, 0);
      final points = <TrackPoint>[
        ...makeStraightTrack(seconds: 30, speedMps: 0.0, start: t0),
        // 10秒だけ高速(最低20秒未満)
        ...makeStraightTrack(
            seconds: 10,
            speedMps: 3.5,
            start: t0.add(const Duration(seconds: 31))),
        ...makeStraightTrack(
            seconds: 30,
            speedMps: 0.0,
            start: t0.add(const Duration(seconds: 42))),
      ];
      final pieces = analyzer.detectPieces(points);
      expect(pieces, isEmpty);
    });

    test('艇種別の基準より速い区間だけをピースにする', () {
      final points = makeStraightTrack(seconds: 60, speedMps: 2.5);

      expect(
        analyzer.detectPieces(points, boatTypeName: 'r_1x'),
        hasLength(1),
      );
      expect(
        analyzer.detectPieces(points, boatTypeName: 'r_2x'),
        isEmpty,
      );
    });

    test('15秒以内の一時的な低下ではピースを分割しない', () {
      final t0 = DateTime(2026, 7, 7, 6, 0, 0);
      final points = <TrackPoint>[
        ...makeStraightTrack(seconds: 45, speedMps: 2.7, start: t0),
        ...makeStraightTrack(
          seconds: 10,
          speedMps: 1.5,
          start: t0.add(const Duration(seconds: 46)),
        ),
        ...makeStraightTrack(
          seconds: 45,
          speedMps: 2.7,
          start: t0.add(const Duration(seconds: 57)),
        ),
      ];

      final pieces = analyzer.detectPieces(points, boatTypeName: 'r_2x');

      expect(pieces, hasLength(1));
      expect(pieces.single.durationSec, greaterThan(80));
    });
  });

  group('警告エピソード', () {
    AlertDiagnosticEvent event(int second) => AlertDiagnosticEvent(
          t: DateTime(2026, 7, 23, 6).add(Duration(seconds: second)),
          event: 'observation',
          alertId: 'bridge-1',
          detectorId: 'static_collision',
          category: 'bridge',
          phase: 'alerting',
          isPrimary: true,
          riskLevel: second == 1 ? 3 : 2,
          currentOverlap: second == 2,
          confidence: 1,
          dataQuality: 'good',
          distanceMeters: 10 - second.toDouble(),
        );

    test('3秒以内の同一警告を1エピソードへ束ねる', () {
      final episodes = analyzer.detectAlertEpisodes([
        event(0),
        event(1),
        event(2),
        event(10),
      ]);

      expect(episodes, hasLength(2));
      expect(episodes.first.maxRiskLevel, 3);
      expect(episodes.first.hadCurrentOverlap, isTrue);
      expect(episodes.first.minimumDistanceMeters, 8);
      expect(episodes.first.id, contains('@'));
    });

    test('警告開始時刻に最も近い航跡点を返す', () {
      final start = DateTime(2026, 7, 23, 6);
      final points = makeStraightTrack(
        seconds: 10,
        speedMps: 2,
        start: start,
      );

      final point = analyzer.nearestTrackPoint(
        points,
        start.add(const Duration(milliseconds: 6200)),
      );

      expect(point?.t, start.add(const Duration(seconds: 6)));
    });
  });
}
