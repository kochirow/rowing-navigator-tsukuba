// 実機ログの航跡を、現在の固定障害物・提示パイプラインへ1Hzで再生する。
//
// 使い方:
//   dart run tool/replay_alerts.dart --session \
//     ../実機テストログデータ/2026_07_28/rowing_diagnostics_1785186811432
//
// `manifest.json` の boatType / dangerZoneOffsets / fixedObstacleCalibrations
// を使う。端末ごとの実運用設定を再現しない比較は、設定値を変える作業の
// 回帰確認として意味を持たないためである。
import 'dart:convert';
import 'dart:io';

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/models/alert_candidate.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import 'package:rowing_navigator/models/danger_zone_settings.dart';
import 'package:rowing_navigator/models/fixed_obstacle_calibration.dart';
import 'package:rowing_navigator/models/safety_snapshot.dart';
import 'package:rowing_navigator/models/static_obstacle_model.dart';
import 'package:rowing_navigator/services/channel_centerline.dart';
import 'package:rowing_navigator/services/collision_risk_evaluator_service.dart';
import 'package:rowing_navigator/services/fixed_obstacle_calibration_service.dart';
import 'package:rowing_navigator/services/legacy_danger_zone_generator.dart';
import 'package:rowing_navigator/services/safety_orchestrator.dart';
import 'package:rowing_navigator/types/boat_type.dart';
import 'package:rowing_navigator/utils/metric_polygon_buffer.dart';

const _defaultHazardProfilePath = 'assets/data/sakuragawa_obstacles.json';

Future<void> main(List<String> args) async {
  final sessionPath = _readSessionArgument(args);
  if (sessionPath == null) {
    stderr.writeln(
      'Usage: dart run tool/replay_alerts.dart --session <diagnostic-directory>',
    );
    exitCode = 64;
    return;
  }
  try {
    final result = await replaySessionDirectory(Directory(sessionPath));
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(result.toJson()));
  } on FormatException catch (error) {
    stderr.writeln('Replay input is invalid: $error');
    exitCode = 65;
  } on FileSystemException catch (error) {
    stderr.writeln('Replay input cannot be read: ${error.message}');
    exitCode = 66;
  }
}

String? _readSessionArgument(List<String> args) {
  for (var index = 0; index < args.length; index++) {
    if (args[index] != '--session') continue;
    if (index + 1 >= args.length) return null;
    return args[index + 1];
  }
  return null;
}

/// A stable, JSON-serializable replay result.  Counts are deliberately based
/// on the warning state machine, not audio-player events: audio hardware is
/// outside this regression route.
class ReplayAlertResult {
  final String sessionId;
  final String boatType;
  final int sampleCount;
  final Map<String, int> episodeCount;
  final Map<String, int> alertingSeconds;
  final Map<String, int> bandHistogram;
  final double currentOverlapRatio;
  final Map<String, double?> tteDistribution;
  final Map<String, List<double>> firstAlertDistanceMeters;

  const ReplayAlertResult({
    required this.sessionId,
    required this.boatType,
    required this.sampleCount,
    required this.episodeCount,
    required this.alertingSeconds,
    required this.bandHistogram,
    required this.currentOverlapRatio,
    required this.tteDistribution,
    required this.firstAlertDistanceMeters,
  });

  int get episodeTotal =>
      episodeCount.values.fold(0, (total, count) => total + count);

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'boatType': boatType,
        'sampleCount': sampleCount,
        'episodeCount': _sortedCounts(episodeCount),
        'alertingSeconds': _sortedCounts(alertingSeconds),
        'bandHistogram': {
          for (final band in const ['imminent', 'approaching', 'monitoring'])
            band: bandHistogram[band] ?? 0,
        },
        'currentOverlapRatio': currentOverlapRatio,
        'tteDistribution': tteDistribution,
        'firstAlertDistanceMeters': _sortedDistances(firstAlertDistanceMeters),
      };

  static Map<String, int> _sortedCounts(Map<String, int> input) => {
        for (final entry
            in input.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
          entry.key: entry.value,
      };

  static Map<String, List<double>> _sortedDistances(
    Map<String, List<double>> input,
  ) =>
      {
        for (final entry
            in input.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
          entry.key: List<double>.unmodifiable(entry.value),
      };
}

/// Replays one diagnostic package.  The public entry point is used by the
/// golden test as well as the command-line tool, so both paths execute exactly
/// the same evaluator/orchestrator code.
Future<ReplayAlertResult> replaySessionDirectory(
  Directory sessionDirectory, {
  String hazardProfilePath = _defaultHazardProfilePath,
}) async {
  final manifest =
      _readJsonObject(File('${sessionDirectory.path}/manifest.json'));
  final session = _requiredObject(manifest, 'session');
  final settings = _requiredObject(manifest, 'settings');
  final sessionId = _requiredString(session, 'id');
  final boatTypeName = _requiredString(settings, 'boatType');
  final boatType = _boatTypeFromName(boatTypeName);
  final startedAt =
      DateTime.parse(_requiredString(session, 'startedAt')).toUtc();
  final warningTimeSeconds =
      _finiteNumber(settings['warningTimeSeconds']) ?? 10;
  final profile = _readJsonObject(File(hazardProfilePath));
  final obstacles = _buildReplayObstacles(profile, settings);
  final centerline = _buildCenterline(profile);
  final samples = _readOneHertzSamples(
    File('${sessionDirectory.path}/track.csv'),
    startedAt: startedAt,
  );

  final evaluator = CollisionRiskEvaluatorService();
  final orchestrator = SafetyOrchestrator(
    sessionId: 'replay-$sessionId',
    sessionGeneration: 1,
  );
  final episodeCount = <String, int>{};
  final alertingSeconds = <String, int>{};
  final bandHistogram = <String, int>{
    'imminent': 0,
    'approaching': 0,
    'monitoring': 0,
  };
  final firstAlertDistanceMeters = <String, List<double>>{};
  final tteSeconds = <double>[];
  var overlapSamples = 0;

  for (final sample in samples) {
    final boat = Boat(
      boatId: 'replay-own-boat',
      boatType: boatType,
      lat: sample.latitude,
      lng: sample.longitude,
      heading: sample.headingDegrees,
      speed: sample.speedMetersPerSecond,
      timestamp: sample.at,
      accuracy: sample.accuracyMeters,
    );
    final assessment = evaluator.assessRisk(
      boat,
      const [],
      obstacles,
      warningTimeSeconds: warningTimeSeconds,
      centerline: centerline,
    );
    if (assessment.currentOverlap) overlapSamples++;
    for (final threat in assessment.threats) {
      final seconds =
          threat.threat.continuousIntersection?.firstEntryTimeSeconds;
      if (seconds != null && seconds.isFinite && seconds >= 0) {
        tteSeconds.add(seconds);
      }
    }
    final result = orchestrator.processAssessment(
      assessment: assessment,
      evaluatedAt: sample.at,
      ownSpeedMetersPerSecond: boat.speed,
      capabilities: const CapabilitySnapshot(
        gpsUsable: true,
        staticProfileUsable: true,
        insideSupportedCoverage: true,
        audioUsable: true,
      ),
    );
    for (final active in result.snapshot.activeAlerts) {
      if (active.phase != AlertPhase.alerting) continue;
      _increment(alertingSeconds, active.candidate.category);
    }
    final candidatesById = {
      for (final view in result.state.alerts)
        view.candidate.alertId: view.candidate,
    };
    for (final transition in result.state.transitions) {
      if (transition.to != AlertPhase.alerting) continue;
      final alert = candidatesById[transition.alertId];
      if (alert == null) continue;
      _increment(episodeCount, alert.category);
      final band = _presentationBand(alert.behavior);
      if (band != null) _increment(bandHistogram, band);
      final distance = alert.distanceMeters;
      if (distance != null && distance.isFinite) {
        firstAlertDistanceMeters
            .putIfAbsent(alert.category, () => <double>[])
            .add(distance);
      }
    }
  }

  return ReplayAlertResult(
    sessionId: sessionId,
    boatType: boatTypeName,
    sampleCount: samples.length,
    episodeCount: episodeCount,
    alertingSeconds: alertingSeconds,
    bandHistogram: bandHistogram,
    currentOverlapRatio: samples.isEmpty ? 0 : overlapSamples / samples.length,
    tteDistribution: _distribution(tteSeconds),
    firstAlertDistanceMeters: firstAlertDistanceMeters,
  );
}

void _increment(Map<String, int> counts, String key) {
  counts[key] = (counts[key] ?? 0) + 1;
}

String? _presentationBand(AlertBehavior behavior) => switch (behavior) {
      AlertBehavior.continuousAction => 'imminent',
      AlertBehavior.singleAction => 'approaching',
      AlertBehavior.visualOnly => 'monitoring',
      // カーブ・逆走は「区域進入」イベントで、TTEバンドの対象ではない。
      AlertBehavior.entryEvent || AlertBehavior.persistentSystemFault => null,
    };

Map<String, double?> _distribution(List<double> values) {
  if (values.isEmpty) {
    return const {'p10': null, 'p50': null, 'p90': null};
  }
  final sorted = List<double>.of(values)..sort();
  return {
    'p10': _percentile(sorted, 0.10),
    'p50': _percentile(sorted, 0.50),
    'p90': _percentile(sorted, 0.90),
  };
}

double _percentile(List<double> sorted, double percentile) {
  if (sorted.length == 1) return sorted.single;
  final index = percentile * (sorted.length - 1);
  final lower = index.floor();
  final upper = index.ceil();
  if (lower == upper) return sorted[lower];
  final fraction = index - lower;
  return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction;
}

List<_ReplaySample> _readOneHertzSamples(
  File trackFile, {
  required DateTime startedAt,
}) {
  final rows = const LineSplitter().convert(trackFile.readAsStringSync());
  if (rows.isEmpty) throw const FormatException('track.csv is empty');
  final header = rows.first.split(',');
  int column(String name) {
    final index = header.indexOf(name);
    if (index < 0) throw FormatException('track.csv is missing $name');
    return index;
  }

  final elapsedColumn = column('elapsed_ms');
  final timestampColumn = header.indexOf('timestamp');
  final latColumn = column('filtered_lat');
  final lngColumn = column('filtered_lng');
  final speedColumn = column('speed_mps');
  final headingColumn = column('heading_deg');
  final accuracyColumn = column('gnss_accuracy_m');
  final samples = <_ReplaySample>[];
  var lastSecond = -1;
  for (final row in rows.skip(1)) {
    if (row.trim().isEmpty) continue;
    final fields = row.split(',');
    if (fields.length != header.length) {
      throw const FormatException('track.csv contains an invalid CSV row');
    }
    final elapsedMs = int.parse(fields[elapsedColumn]);
    final second = elapsedMs ~/ 1000;
    if (second == lastSecond) continue;
    lastSecond = second;
    final at = timestampColumn >= 0 && fields[timestampColumn].isNotEmpty
        ? DateTime.parse(fields[timestampColumn]).toUtc()
        : startedAt.add(Duration(milliseconds: elapsedMs));
    samples.add(_ReplaySample(
      at: at,
      latitude: double.parse(fields[latColumn]),
      longitude: double.parse(fields[lngColumn]),
      speedMetersPerSecond: double.tryParse(fields[speedColumn]) ?? 0,
      headingDegrees: double.tryParse(fields[headingColumn]) ?? 0,
      accuracyMeters: double.tryParse(fields[accuracyColumn]),
    ));
  }
  return List.unmodifiable(samples);
}

class _ReplaySample {
  final DateTime at;
  final double latitude;
  final double longitude;
  final double speedMetersPerSecond;
  final double headingDegrees;
  final double? accuracyMeters;

  const _ReplaySample({
    required this.at,
    required this.latitude,
    required this.longitude,
    required this.speedMetersPerSecond,
    required this.headingDegrees,
    required this.accuracyMeters,
  });
}

List<StaticObstacle> _buildReplayObstacles(
  Map<String, dynamic> profile,
  Map<String, dynamic> settings,
) {
  final dangerSettings = _dangerZoneSettingsFromManifest(settings);
  final calibrations = _calibrationsFromManifest(settings);
  final calibrationService = FixedObstacleCalibrationService();
  final defaultProximity = _finiteNumber(
    profile['defaultObstacleProximityCautionMeters'],
  );
  final proximity = defaultProximity != null && defaultProximity > 0
      ? defaultProximity
      : null;
  final obstacles = <StaticObstacle>[];

  for (final raw in _requiredList(profile, 'obstacles')) {
    final item = Map<String, dynamic>.from(raw as Map);
    final kind = StaticObstacleKind.fromJson(item['kind'] as String?);
    if (kind == StaticObstacleKind.testZone) {
      continue;
    }
    final sourceId = _requiredString(item, 'id');
    final points = _pointsFromJson(item['points']);
    obstacles.add(StaticObstacle(
      id: sourceId,
      sourceId: sourceId,
      name: item['name'] as String?,
      points: calibrationService.translatePoints(
        points,
        calibrations[sourceId] ?? const FixedObstacleCalibration(),
      ),
      isDefault: true,
      kind: kind,
      warningAudioAsset: item['warningAudio'] as String?,
    ));
  }

  final baselines = <DangerZoneBaseline>[];
  for (final raw in _requiredList(profile, 'dangerZoneBaselines')) {
    final item = Map<String, dynamic>.from(raw as Map);
    final baseline = DangerZoneBaseline.fromJson(item);
    if (baseline.kind == DangerZoneKind.testZone) {
      continue;
    }
    final calibratedPoints = calibrationService.translatePoints(
      baseline.points,
      calibrations[baseline.id] ?? const FixedObstacleCalibration(),
    );
    if (baseline.kind == DangerZoneKind.driftwood) {
      // 航行中と同じく、閉じた流木外周はリボンへ分解せず1枚へ拡張する。
      obstacles.add(StaticObstacle(
        id: 'fixed_driftwood_01',
        sourceId: baseline.id,
        name: baseline.name,
        points: const MetricPolygonBuffer().expand(
          calibratedPoints,
          dangerSettings[DangerZoneKind.driftwood].waterSideMeters,
        ),
        isDefault: true,
        isManaged: true,
        proximityCautionDistanceMeters: proximity,
        kind: StaticObstacleKind.driftwood,
        warningAudioAsset: baseline.warningAudioAsset,
      ));
      continue;
    }
    baselines.add(DangerZoneBaseline(
      id: baseline.id,
      name: baseline.name,
      kind: baseline.kind,
      points: calibratedPoints,
      warningAudioAsset: baseline.warningAudioAsset,
    ));
  }
  obstacles.addAll(LegacyDangerZoneGenerator().generate(
    baselines: baselines,
    settings: dangerSettings,
    proximityCautionDistanceMeters: proximity,
  ));
  return List.unmodifiable(obstacles);
}

DangerZoneSettings _dangerZoneSettingsFromManifest(
  Map<String, dynamic> settings,
) {
  final rawOffsets = _requiredObject(settings, 'dangerZoneOffsets');
  var result = DangerZoneSettings.defaults();
  for (final kind in DangerZoneKind.values) {
    final raw = rawOffsets[kind.name];
    if (raw is! Map) {
      throw FormatException(
          'manifest settings.dangerZoneOffsets.${kind.name} is missing');
    }
    final offsets = Map<String, dynamic>.from(raw);
    final water = _finiteNumber(offsets['waterSideMeters']);
    final land = _finiteNumber(offsets['landSideMeters']);
    if (water == null || land == null || water < 0 || land < 0) {
      throw FormatException('Invalid offsets for ${kind.name}');
    }
    result = result.withOffsets(
      kind,
      DangerZoneOffsets(waterSideMeters: water, landSideMeters: land),
    );
  }
  return result;
}

Map<String, FixedObstacleCalibration> _calibrationsFromManifest(
  Map<String, dynamic> settings,
) {
  final raw = settings['fixedObstacleCalibrations'];
  if (raw == null) return const {};
  if (raw is! List) {
    throw const FormatException('fixedObstacleCalibrations must be an array');
  }
  final calibrations = <String, FixedObstacleCalibration>{};
  for (final item in raw) {
    if (item is! Map) {
      throw const FormatException('Invalid fixed obstacle calibration');
    }
    final map = Map<String, dynamic>.from(item);
    final sourceId = _requiredString(map, 'sourceId');
    map.remove('sourceId');
    final calibration = FixedObstacleCalibration.fromJson(map);
    if (!calibration.isZero) calibrations[sourceId] = calibration;
  }
  return calibrations;
}

ChannelCenterline? _buildCenterline(Map<String, dynamic> profile) {
  final explicit = profile['channelCenterline'];
  if (explicit is Map && explicit['points'] is List) {
    final centerline =
        ChannelCenterline.fromPolyline(_pointsFromJson(explicit['points']));
    if (centerline != null) return centerline;
  }
  final shores = <List<LatLng>>[];
  for (final raw in _requiredList(profile, 'dangerZoneBaselines')) {
    final baseline =
        DangerZoneBaseline.fromJson(Map<String, dynamic>.from(raw as Map));
    if (baseline.kind == DangerZoneKind.shore) shores.add(baseline.points);
  }
  if (shores.length < 2) return null;
  shores.sort((a, b) => b.length.compareTo(a.length));
  return ChannelCenterline.fromShorelines(
    firstShore: shores[0],
    secondShore: shores[1],
  );
}

List<LatLng> _pointsFromJson(Object? raw) {
  if (raw is! List) throw const FormatException('points must be an array');
  return raw.map<LatLng>((point) {
    if (point is! Map) throw const FormatException('point must be an object');
    final lat = _finiteNumber(point['lat']);
    final lng = _finiteNumber(point['lng']);
    if (lat == null || lng == null) {
      throw const FormatException('Invalid point');
    }
    return LatLng(lat, lng);
  }).toList(growable: false);
}

BoatType _boatTypeFromName(String value) {
  for (final boatType in BoatType.values) {
    if (boatType.name == value) return boatType;
  }
  throw FormatException('Unknown boatType: $value');
}

Map<String, dynamic> _readJsonObject(File file) {
  final raw = jsonDecode(file.readAsStringSync());
  if (raw is! Map) throw FormatException('${file.path} must contain an object');
  return Map<String, dynamic>.from(raw);
}

Map<String, dynamic> _requiredObject(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value is! Map) throw FormatException('$key must be an object');
  return Map<String, dynamic>.from(value);
}

List<dynamic> _requiredList(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value is! List) throw FormatException('$key must be an array');
  return value;
}

String _requiredString(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$key must be a string');
  }
  return value;
}

double? _finiteNumber(Object? value) {
  if (value is! num || !value.isFinite) return null;
  return value.toDouble();
}
