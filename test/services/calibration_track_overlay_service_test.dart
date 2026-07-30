import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/session_model.dart';
import 'package:rowing_navigator/services/calibration_track_overlay_service.dart';

TrackPoint point(
  DateTime t,
  double lat, {
  double lng = 140.2,
  double? accuracy = 5,
  double? rawLat,
  double? rawLng,
  String gnssQuality = 'good',
}) {
  return TrackPoint(
    t: t,
    lat: lat,
    lng: lng,
    rawLat: rawLat,
    rawLng: rawLng,
    speed: 2,
    heading: 0,
    safetyLevel: 'safe',
    gnssAccuracyMeters: accuracy,
    gnssQuality: gnssQuality,
  );
}

Session sessionWith(
  List<TrackPoint> points, {
  List<AlertDiagnosticEvent> alertEvents = const [],
  Map<String, String> ratings = const {},
}) {
  final startedAt = points.first.t;
  return Session(
    id: 'session-${startedAt.millisecondsSinceEpoch}',
    startedAt: startedAt,
    endedAt: points.last.t,
    boatTypeName: 'r_1x',
    seatPosLabel: '1',
    points: points,
    summary: SessionSummary(
      totalDistanceMeters: 0,
      durationSec: points.last.t.difference(startedAt).inSeconds.toDouble(),
      maxSpeed: 2,
      avgSpeed: 2,
      splits: const [],
      pieces: const [],
      alertCounts: const {},
    ),
    alertEvents: alertEvents,
    alertEpisodeRatings: ratings,
  );
}

void main() {
  final service = CalibrationTrackOverlayService();
  final t0 = DateTime.utc(2026, 7, 23);

  test('GPS精度に応じて航跡を通常・淡色へ分け25m超を接続しない', () {
    final points = [
      point(t0, 36.0000, accuracy: 5),
      point(t0.add(const Duration(seconds: 1)), 36.0001, accuracy: 7),
      point(t0.add(const Duration(seconds: 2)), 36.0002, accuracy: 18),
      point(t0.add(const Duration(seconds: 3)), 36.0003, accuracy: 20),
      point(t0.add(const Duration(seconds: 4)), 36.0004, accuracy: 40),
      point(t0.add(const Duration(seconds: 5)), 36.0005, accuracy: 5),
      point(t0.add(const Duration(seconds: 6)), 36.0006, accuracy: 5),
    ];

    final segments = service.buildFilteredSegments(points);

    expect(
      segments.map((segment) => segment.quality),
      [
        CalibrationTrackQuality.reliable,
        CalibrationTrackQuality.degraded,
        CalibrationTrackQuality.reliable,
      ],
    );
    expect(segments.map((segment) => segment.vertices.length), [2, 3, 2]);
    expect(segments.last.vertices.first.lat, 36.0005);
  });

  test('生GPS座標が欠けた区間は線で跨がない', () {
    final points = [
      point(t0, 36.0000, rawLat: 36.00001, rawLng: 140.20001),
      point(
        t0.add(const Duration(seconds: 1)),
        36.0001,
        rawLat: 36.00011,
        rawLng: 140.20001,
      ),
      point(t0.add(const Duration(seconds: 2)), 36.0002),
      point(
        t0.add(const Duration(seconds: 3)),
        36.0003,
        rawLat: 36.00031,
        rawLng: 140.20001,
      ),
      point(
        t0.add(const Duration(seconds: 4)),
        36.0004,
        rawLat: 36.00041,
        rawLng: 140.20001,
      ),
    ];

    final segments = service.buildRawSegments(points);

    expect(segments, hasLength(2));
    expect(segments.every((segment) => segment.vertices.length == 2), isTrue);
  });

  test('反対方向と往復記録を誤認しない方向ラベルを返す', () {
    final northbound = sessionWith([
      point(t0, 36.0000),
      point(t0.add(const Duration(seconds: 1)), 36.0010),
    ]);
    final southbound = sessionWith([
      point(t0, 36.0010),
      point(t0.add(const Duration(seconds: 1)), 36.0000),
    ]);
    final roundTrip = sessionWith([
      point(t0, 36.0000),
      point(t0.add(const Duration(seconds: 1)), 36.0010),
      point(t0.add(const Duration(seconds: 2)), 36.0000),
    ]);

    expect(service.directionLabel(northbound), '北向き');
    expect(service.directionLabel(southbound), '南向き');
    expect(service.directionLabel(roundTrip), '往復・方向混在');
  });

  test('警告開始と位置ずれ評価を航跡時刻へ関連付ける', () {
    final alertAt = t0.add(const Duration(seconds: 1));
    final alertId = 'fixed:bridge_1';
    final episodeId =
        '${Uri.encodeComponent(alertId)}@${alertAt.millisecondsSinceEpoch}';
    final points = [
      point(t0, 36.0000),
      point(alertAt, 36.0001),
      point(t0.add(const Duration(seconds: 2)), 36.0002),
    ];
    final session = sessionWith(
      points,
      alertEvents: [
        AlertDiagnosticEvent(
          t: alertAt,
          event: 'observation',
          alertId: alertId,
          detectorId: 'static_obstacle',
          category: 'bridge',
          phase: 'alerting',
          isPrimary: true,
          riskLevel: 2,
          currentOverlap: false,
          confidence: 1,
          dataQuality: 'good',
        ),
      ],
      ratings: {
        episodeId: AlertEpisodeRating.positionMismatch.name,
      },
    );

    final pins = service.warningPins(session);

    expect(pins, hasLength(1));
    expect(pins.single.trackPoint.lat, 36.0001);
    expect(pins.single.isPositionMismatch, isTrue);
    expect(pins.single.category, 'bridge');
  });
}
