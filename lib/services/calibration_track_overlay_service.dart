import 'dart:math';

import '../models/session_model.dart';
import 'session_analyzer_service.dart';

/// 固定障害物の現地校正で重ねる航跡の測位品質。
enum CalibrationTrackQuality {
  reliable,
  degraded,
}

/// 地図SDKへ依存しない航跡上の座標。
class CalibrationTrackVertex {
  final double lat;
  final double lng;
  final DateTime t;
  final double? accuracyMeters;

  const CalibrationTrackVertex({
    required this.lat,
    required this.lng,
    required this.t,
    required this.accuracyMeters,
  });
}

/// 同じ測位品質が連続する航跡線分。
class CalibrationTrackSegment {
  final CalibrationTrackQuality quality;
  final List<CalibrationTrackVertex> vertices;

  const CalibrationTrackSegment({
    required this.quality,
    required this.vertices,
  });
}

/// 校正画面へ表示する警告開始地点。
class CalibrationWarningPin {
  final String episodeId;
  final String category;
  final DateTime startedAt;
  final TrackPoint trackPoint;
  final bool isPositionMismatch;

  const CalibrationWarningPin({
    required this.episodeId,
    required this.category,
    required this.startedAt,
    required this.trackPoint,
    required this.isPositionMismatch,
  });
}

/// 複数航行を校正画面へ安全に重ねるための純粋ロジック。
///
/// - 12m超の点は淡色
/// - 25m超またはunusableの点は線を接続しない
/// - 古い記録（精度値なし）は通常色で表示する
class CalibrationTrackOverlayService {
  static const degradedAccuracyMeters = 12.0;
  static const excludedAccuracyMeters = 25.0;

  final SessionAnalyzerService _sessionAnalyzer;

  CalibrationTrackOverlayService({
    SessionAnalyzerService? sessionAnalyzer,
  }) : _sessionAnalyzer = sessionAnalyzer ?? SessionAnalyzerService();

  List<CalibrationTrackSegment> buildFilteredSegments(
    List<TrackPoint> points,
  ) {
    return _buildSegments(points, useRawCoordinates: false);
  }

  List<CalibrationTrackSegment> buildRawSegments(
    List<TrackPoint> points,
  ) {
    return _buildSegments(points, useRawCoordinates: true);
  }

  /// セッションの開始点から終了点への概略方位。
  ///
  /// 始終点が近い、または航行距離に対して変位が小さい記録は、
  /// 一方向と誤認させないよう「往復・方向混在」とする。
  String directionLabel(Session session) {
    final usable = session.points
        .where((point) => _pointQuality(point) != _PointQuality.excluded)
        .toList(growable: false);
    if (usable.length < 2) return '方向不明';

    final first = usable.first;
    final last = usable.last;
    final displacement = SessionAnalyzerService.distanceMeters(
      first.lat,
      first.lng,
      last.lat,
      last.lng,
    );
    var pathDistance = 0.0;
    for (var index = 1; index < usable.length; index++) {
      pathDistance += SessionAnalyzerService.distanceMeters(
        usable[index - 1].lat,
        usable[index - 1].lng,
        usable[index].lat,
        usable[index].lng,
      );
    }
    if (displacement < 20 ||
        (pathDistance >= 100 && displacement / pathDistance < 0.15)) {
      return '往復・方向混在';
    }

    final bearing = _bearingDegrees(
      first.lat,
      first.lng,
      last.lat,
      last.lng,
    );
    const labels = ['北向き', '北東向き', '東向き', '南東向き', '南向き', '南西向き', '西向き', '北西向き'];
    final index = ((bearing + 22.5) ~/ 45) % labels.length;
    return labels[index];
  }

  List<CalibrationWarningPin> warningPins(
    Session session, {
    int maximumPins = 200,
  }) {
    if (session.points.isEmpty || maximumPins <= 0) return const [];
    final episodes = _sessionAnalyzer
        .detectAlertEpisodes(session.alertEvents)
        .take(maximumPins);
    return List.unmodifiable(episodes.map((episode) {
      final point = _sessionAnalyzer.nearestTrackPoint(
        session.points,
        episode.startedAt,
      )!;
      return CalibrationWarningPin(
        episodeId: episode.id,
        category: episode.category,
        startedAt: episode.startedAt,
        trackPoint: point,
        isPositionMismatch: session.alertEpisodeRatings[episode.id] ==
            AlertEpisodeRating.positionMismatch.name,
      );
    }));
  }

  List<CalibrationTrackSegment> _buildSegments(
    List<TrackPoint> points, {
    required bool useRawCoordinates,
  }) {
    if (points.length < 2) return const [];
    final result = <CalibrationTrackSegment>[];
    CalibrationTrackQuality? currentQuality;
    var currentVertices = <CalibrationTrackVertex>[];

    void closeCurrent() {
      if (currentQuality != null && currentVertices.length >= 2) {
        result.add(CalibrationTrackSegment(
          quality: currentQuality!,
          vertices: List.unmodifiable(currentVertices),
        ));
      }
      currentQuality = null;
      currentVertices = <CalibrationTrackVertex>[];
    }

    for (var index = 1; index < points.length; index++) {
      final previous = points[index - 1];
      final current = points[index];
      final previousVertex = _vertexFor(
        previous,
        useRawCoordinates: useRawCoordinates,
      );
      final currentVertex = _vertexFor(
        current,
        useRawCoordinates: useRawCoordinates,
      );
      final pairQuality = _pairQuality(previous, current);
      if (previousVertex == null ||
          currentVertex == null ||
          pairQuality == null) {
        closeCurrent();
        continue;
      }
      if (currentQuality != pairQuality) {
        closeCurrent();
        currentQuality = pairQuality;
        currentVertices = [previousVertex, currentVertex];
      } else {
        currentVertices.add(currentVertex);
      }
    }
    closeCurrent();
    return List.unmodifiable(result);
  }

  CalibrationTrackVertex? _vertexFor(
    TrackPoint point, {
    required bool useRawCoordinates,
  }) {
    final lat = useRawCoordinates ? point.rawLat : point.lat;
    final lng = useRawCoordinates ? point.rawLng : point.lng;
    if (lat == null ||
        lng == null ||
        !lat.isFinite ||
        !lng.isFinite ||
        lat < -90 ||
        lat > 90 ||
        lng < -180 ||
        lng > 180) {
      return null;
    }
    return CalibrationTrackVertex(
      lat: lat,
      lng: lng,
      t: point.t,
      accuracyMeters: point.gnssAccuracyMeters,
    );
  }

  CalibrationTrackQuality? _pairQuality(
    TrackPoint first,
    TrackPoint second,
  ) {
    final firstQuality = _pointQuality(first);
    final secondQuality = _pointQuality(second);
    if (firstQuality == _PointQuality.excluded ||
        secondQuality == _PointQuality.excluded) {
      return null;
    }
    if (firstQuality == _PointQuality.degraded ||
        secondQuality == _PointQuality.degraded) {
      return CalibrationTrackQuality.degraded;
    }
    return CalibrationTrackQuality.reliable;
  }

  _PointQuality _pointQuality(TrackPoint point) {
    if (point.gnssQuality == 'unusable') return _PointQuality.excluded;
    final accuracy = point.gnssAccuracyMeters;
    if (accuracy != null) {
      if (!accuracy.isFinite || accuracy < 0) return _PointQuality.excluded;
      if (accuracy > excludedAccuracyMeters) return _PointQuality.excluded;
      if (accuracy > degradedAccuracyMeters) return _PointQuality.degraded;
    }
    if (point.gnssQuality == 'degraded') return _PointQuality.degraded;
    return _PointQuality.reliable;
  }

  double _bearingDegrees(
    double fromLat,
    double fromLng,
    double toLat,
    double toLng,
  ) {
    final fromLatRad = fromLat * pi / 180;
    final toLatRad = toLat * pi / 180;
    final deltaLng = (toLng - fromLng) * pi / 180;
    final y = sin(deltaLng) * cos(toLatRad);
    final x = cos(fromLatRad) * sin(toLatRad) -
        sin(fromLatRad) * cos(toLatRad) * cos(deltaLng);
    return (atan2(y, x) * 180 / pi + 360) % 360;
  }
}

enum _PointQuality {
  reliable,
  degraded,
  excluded,
}
