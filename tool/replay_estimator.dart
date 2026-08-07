// Raw GNSS driven estimator replay. This tool deliberately never feeds
// filtered_* back into a solution; those columns are comparison-only.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/services/bounded_position_set.dart';
import 'package:rowing_navigator/services/conservative_position_estimator.dart';
import 'package:rowing_navigator/services/robust_position_estimator.dart';

const _logDir = String.fromEnvironment('LOG_DIR');
const _outPath = String.fromEnvironment('OUT');

class ReplayFix {
  final DateTime timestamp;
  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final double? speedMetersPerSecond;
  final double? headingDegrees;
  final String? quality;
  final double? recordedFilteredLatitude;
  final double? recordedFilteredLongitude;

  const ReplayFix({
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    this.speedMetersPerSecond,
    this.headingDegrees,
    this.quality,
    this.recordedFilteredLatitude,
    this.recordedFilteredLongitude,
  });
}

class ReplaySolutionOutput {
  final LatLng representativePoint;
  final double speedMetersPerSecond;
  final double headingDegrees;
  final double uncertaintyMeters;
  final BoundedPositionSet? safetySet;
  final String dispositionName;
  final double? normalizedInnovationSquared;

  const ReplaySolutionOutput({
    required this.representativePoint,
    required this.speedMetersPerSecond,
    required this.headingDegrees,
    required this.uncertaintyMeters,
    required this.dispositionName,
    this.safetySet,
    this.normalizedInnovationSquared,
  });
}

abstract class ReplaySolution {
  String get id;
  ReplaySolutionOutput? step({required Duration elapsed, ReplayFix? fix});
}

class S0RawSolution implements ReplaySolution {
  ReplayFix? _latest;
  @override
  String get id => 's0_raw';

  @override
  ReplaySolutionOutput? step({required Duration elapsed, ReplayFix? fix}) {
    if (fix != null) _latest = fix;
    final current = _latest;
    if (current == null) return null;
    final speed = current.speedMetersPerSecond ?? 0;
    final heading = current.headingDegrees ?? 0;
    return ReplaySolutionOutput(
      representativePoint: LatLng(current.latitude, current.longitude),
      speedMetersPerSecond: speed,
      headingDegrees: heading,
      uncertaintyMeters: current.accuracyMeters,
      safetySet: CircleSet(
        representativePoint: LatLng(current.latitude, current.longitude),
        radiusMeters: current.accuracyMeters,
      ),
      dispositionName: fix == null ? 'held' : 'accepted',
    );
  }
}

class S1KalmanSolution implements ReplaySolution {
  final RobustPositionEstimator _estimator;
  S1KalmanSolution({RobustPositionEstimator? estimator})
      : _estimator = estimator ?? RobustPositionEstimator();
  @override
  String get id => 's1_kalman';

  @override
  ReplaySolutionOutput? step({required Duration elapsed, ReplayFix? fix}) {
    final estimate = fix == null
        ? _estimator.predict(elapsed: elapsed)
        : _estimator.update(
            latitude: fix.latitude,
            longitude: fix.longitude,
            accuracyMeters: fix.accuracyMeters,
            elapsed: elapsed,
            speedMetersPerSecond: fix.speedMetersPerSecond,
            headingDegrees: fix.headingDegrees,
          );
    if (estimate == null) return null;
    return ReplaySolutionOutput(
      representativePoint: LatLng(estimate.latitude, estimate.longitude),
      speedMetersPerSecond: estimate.speedMetersPerSecond,
      headingDegrees: estimate.headingDegrees,
      uncertaintyMeters: estimate.uncertaintyMeters,
      safetySet: CircleSet(
        representativePoint: LatLng(estimate.latitude, estimate.longitude),
        radiusMeters: estimate.uncertaintyMeters,
      ),
      dispositionName: estimate.disposition.name,
      normalizedInnovationSquared: estimate.normalizedInnovationSquared,
    );
  }
}

/// The actual S1 output recorded by the application. For Stage 2 comparison
/// this is the trustworthy S1 reference; rerunning the estimator is not.
class S1RecordedSolution extends S0RawSolution {
  @override
  String get id => 's1_recorded';

  @override
  ReplaySolutionOutput? step({required Duration elapsed, ReplayFix? fix}) {
    final raw = super.step(elapsed: elapsed, fix: fix);
    if (raw == null ||
        fix == null ||
        fix.recordedFilteredLatitude == null ||
        fix.recordedFilteredLongitude == null) {
      return raw;
    }
    final point = LatLng(
      fix.recordedFilteredLatitude!,
      fix.recordedFilteredLongitude!,
    );
    return ReplaySolutionOutput(
      representativePoint: point,
      speedMetersPerSecond: raw.speedMetersPerSecond,
      headingDegrees: raw.headingDegrees,
      uncertaintyMeters: raw.uncertaintyMeters,
      safetySet: CircleSet(
        representativePoint: point,
        radiusMeters: raw.uncertaintyMeters,
      ),
      dispositionName: 'recorded',
    );
  }
}

/// Stage 2's production S2, driven only by raw fixes.
///
/// この再生器は本番の[ConservativePositionEstimator]を直接使う。再生だけ
/// 別のalpha-beta解を使うと、Stage 2の受け入れ指標が出荷コードを測らない。
class S2ConservativeSolution implements ReplaySolution {
  final ConservativePositionEstimator _estimator =
      ConservativePositionEstimator();
  @override
  String get id => 's2_conservative';

  @override
  ReplaySolutionOutput? step({required Duration elapsed, ReplayFix? fix}) {
    final output = fix == null
        ? _estimator.predict(elapsed: elapsed)
        : _estimator
            .update(
              fix: ConservativeFix(
                position: LatLng(fix.latitude, fix.longitude),
                timestamp: fix.timestamp,
                elapsed: elapsed,
                accuracyMeters: fix.accuracyMeters,
                speedMetersPerSecond: fix.speedMetersPerSecond,
                headingDegrees: fix.headingDegrees,
              ),
            )
            .output;
    if (output == null) return null;
    return ReplaySolutionOutput(
      representativePoint: output.representativePoint,
      speedMetersPerSecond: output.speedMetersPerSecond,
      headingDegrees: output.headingDegrees,
      uncertaintyMeters: output.uncertaintyMeters,
      safetySet: output.safetySet,
      dispositionName: 'conservative',
    );
  }
}

class ReplayRun {
  final List<ReplayFix> fixes;
  final Map<String, List<ReplaySolutionOutput>> outputs;
  const ReplayRun(this.fixes, this.outputs);

  Map<String, dynamic> toJson() => {
        'inputFixCount': fixes.length,
        'solutions': {
          for (final entry in outputs.entries)
            entry.key: entry.value
                .map((output) => {
                      'lat': output.representativePoint.latitude,
                      'lng': output.representativePoint.longitude,
                      'speedMps': output.speedMetersPerSecond,
                      'headingDeg': output.headingDegrees,
                      'uncertaintyM': output.uncertaintyMeters,
                      'disposition': output.dispositionName,
                      if (output.normalizedInnovationSquared != null)
                        'nis': output.normalizedInnovationSquared,
                    })
                .toList(),
        },
      };
}

ReplayRun replayFixes(List<ReplayFix> fixes, List<ReplaySolution> solutions) {
  final results = {
    for (final solution in solutions) solution.id: <ReplaySolutionOutput>[]
  };
  if (fixes.isEmpty) return ReplayRun(fixes, results);
  final origin = fixes.first.timestamp;
  for (final fix in fixes) {
    final elapsed = fix.timestamp.difference(origin);
    for (final solution in solutions) {
      final output = solution.step(elapsed: elapsed, fix: fix);
      if (output != null) results[solution.id]!.add(output);
    }
  }
  return ReplayRun(fixes, results);
}

List<ReplayFix> readReplayFixes(File file) {
  final rows = const LineSplitter().convert(file.readAsStringSync());
  if (rows.length < 2) return const [];
  final header = rows.first.split(',');
  int col(String name) => header.indexOf(name);
  final rawLat = col('raw_lat');
  final rawLng = col('raw_lng');
  final timestamp = col('timestamp');
  if (rawLat < 0 || rawLng < 0 || timestamp < 0) {
    throw const FormatException(
        'track.csv requires raw_lat, raw_lng and timestamp');
  }
  double? value(List<String> fields, String name) {
    final index = col(name);
    return index < 0 || index >= fields.length
        ? null
        : double.tryParse(fields[index]);
  }

  final result = <ReplayFix>[];
  for (final row in rows.skip(1)) {
    if (row.trim().isEmpty) continue;
    final fields = row.split(',');
    if (fields.length <= math.max(rawLat, rawLng)) continue;
    final lat = double.tryParse(fields[rawLat]);
    final lng = double.tryParse(fields[rawLng]);
    final at = DateTime.tryParse(fields[timestamp])?.toUtc();
    if (lat == null || lng == null || at == null) continue;
    result.add(ReplayFix(
      timestamp: at,
      latitude: lat,
      longitude: lng,
      accuracyMeters: value(fields, 'gnss_accuracy_m') ?? 10,
      speedMetersPerSecond: value(fields, 'raw_gnss_speed_mps'),
      headingDegrees: value(fields, 'heading_deg'),
      quality: col('gnss_quality') < 0 ? null : fields[col('gnss_quality')],
      recordedFilteredLatitude: value(fields, 'filtered_lat'),
      recordedFilteredLongitude: value(fields, 'filtered_lng'),
    ));
  }
  return result;
}

void main() {
  test('raw駆動推定器再生', () {
    if (_logDir.isEmpty) {
      markTestSkipped('LOG_DIR is not specified');
      return;
    }
    final run = replayFixes(
      readReplayFixes(File('$_logDir/track.csv')),
      [S0RawSolution(), S1RecordedSolution(), S2ConservativeSolution()],
    );
    if (_outPath.isNotEmpty) {
      File(_outPath).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(run.toJson()),
      );
    }
    expect(run.outputs['s0_raw'], isNotEmpty);
  });
}
