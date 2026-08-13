import 'dart:math' as math;

import 'replay_estimator.dart';

class PairMetrics {
  final int pairCount;
  final Map<String, double?> pairDistance;
  final Map<String, double?> excessOverTruth;
  final int countOver8m;
  final int countOver10m;
  final int excursionsOver10m;
  final Duration excursionDuration;
  final double? maximumMeters;
  final Map<String, double?> alongCross;
  final Map<String, double?> stoppedAlongOffset;

  const PairMetrics({
    required this.pairCount,
    required this.pairDistance,
    required this.excessOverTruth,
    required this.countOver8m,
    required this.countOver10m,
    required this.excursionsOver10m,
    required this.excursionDuration,
    required this.maximumMeters,
    required this.alongCross,
    required this.stoppedAlongOffset,
  });

  Map<String, dynamic> toJson() => {
        'pairCount': pairCount,
        'pairDistance': pairDistance,
        'excessOverTruth': excessOverTruth,
        'countOver8m': countOver8m,
        'countOver10m': countOver10m,
        'excursionsOver10m': {
          'count': excursionsOver10m,
          'totalSeconds': excursionDuration.inMilliseconds / 1000,
        },
        'maximumMeters': maximumMeters,
        'alongCross': alongCross,
        'stoppedAlongOffset': stoppedAlongOffset,
      };
}

/// Pairs fixes by nearest UTC timestamp within 0.6 seconds, once only.
PairMetrics computePairMetrics(
  List<ReplayFix> left,
  List<ReplayFix> right, {
  double trueSeparationMeters = 1.75,
  Duration maximumTimestampDelta = const Duration(milliseconds: 600),
}) {
  final matched = <(ReplayFix, ReplayFix)>[];
  var rightStart = 0;
  for (final lhs in left) {
    while (rightStart + 1 < right.length &&
        right[rightStart + 1].timestamp.isBefore(lhs.timestamp)) {
      rightStart++;
    }
    final choices = <ReplayFix>[right[rightStart]];
    if (rightStart + 1 < right.length) choices.add(right[rightStart + 1]);
    final rhs = choices.reduce((a, b) =>
        a.timestamp.difference(lhs.timestamp).abs() <=
                b.timestamp.difference(lhs.timestamp).abs()
            ? a
            : b);
    if (rhs.timestamp.difference(lhs.timestamp).abs() <=
        maximumTimestampDelta) {
      matched.add((lhs, rhs));
    }
  }
  final distances = <double>[];
  final excess = <double>[];
  final along = <double>[];
  final cross = <double>[];
  final stoppedAlong = <double>[];
  var over8 = 0;
  var over10 = 0;
  var excursions = 0;
  var inExcursion = false;
  var excursionMs = 0;
  DateTime? previous;
  for (final pair in matched) {
    final distance = _distance(pair.$1.latitude, pair.$1.longitude,
        pair.$2.latitude, pair.$2.longitude);
    distances.add(distance);
    excess.add(math.max(0, distance - trueSeparationMeters));
    if (distance > 8) over8++;
    if (distance > 10) {
      over10++;
      if (!inExcursion) {
        excursions++;
        inExcursion = true;
      }
      if (previous != null) {
        excursionMs += pair.$1.timestamp
            .difference(previous)
            .inMilliseconds
            .clamp(0, 1000);
      }
    } else {
      inExcursion = false;
    }
    previous = pair.$1.timestamp;
    final decomposition = _alongCross(pair.$1, pair.$2);
    along.add(decomposition.$1.abs());
    cross.add(decomposition.$2.abs());
    if ((pair.$1.speedMetersPerSecond ?? double.infinity) < 0.4) {
      stoppedAlong.add(decomposition.$1.abs());
    }
  }
  return PairMetrics(
    pairCount: matched.length,
    pairDistance: _distribution(distances),
    excessOverTruth: _distribution(excess),
    countOver8m: over8,
    countOver10m: over10,
    excursionsOver10m: excursions,
    excursionDuration: Duration(milliseconds: excursionMs),
    maximumMeters: distances.isEmpty ? null : distances.reduce(math.max),
    alongCross: {
      'absoluteAlongMedian': _percentile(along, .5),
      'absoluteCrossMedian': _percentile(cross, .5),
      'absoluteCrossP99': _percentile(cross, .99),
      'crossOver5Fraction': cross.isEmpty
          ? null
          : cross.where((v) => v > 5).length / cross.length,
    },
    stoppedAlongOffset: _distribution(stoppedAlong),
  );
}

/// Computes the same metrics for one named solution while retaining original
/// timestamps, raw speed and heading for pairing and along/cross decomposition.
PairMetrics computeSolutionPairMetrics(
  ReplayRun left,
  ReplayRun right,
  String solutionId, {
  Duration warmup = const Duration(seconds: 60),
  double trueSeparationMeters = 1.75,
}) {
  List<ReplayFix> projected(ReplayRun run) {
    final outputs = run.outputs[solutionId];
    if (outputs == null || outputs.length != run.fixes.length) {
      throw ArgumentError('solution output is not aligned with fixes: $solutionId');
    }
    final start = run.fixes.first.timestamp;
    return [
      for (var index = 0; index < run.fixes.length; index++)
        if (run.fixes[index].timestamp.difference(start) >= warmup)
          ReplayFix(
            timestamp: run.fixes[index].timestamp,
            latitude: outputs[index].representativePoint.latitude,
            longitude: outputs[index].representativePoint.longitude,
            accuracyMeters: outputs[index].uncertaintyMeters,
            speedMetersPerSecond: outputs[index].speedMetersPerSecond,
            headingDegrees: outputs[index].headingDegrees,
          ),
    ];
  }
  return computePairMetrics(
    projected(left),
    projected(right),
    trueSeparationMeters: trueSeparationMeters,
  );
}

Map<String, double?> _distribution(List<double> values) => {
      'median': _percentile(values, .5),
      'p90': _percentile(values, .9),
      'p99': _percentile(values, .99),
      'max': values.isEmpty ? null : values.reduce(math.max),
    };

double? _percentile(List<double> values, double percentile) {
  if (values.isEmpty) return null;
  final sorted = [...values]..sort();
  final index = (percentile * (sorted.length - 1)).round();
  return sorted[index];
}

double _distance(double lat1, double lng1, double lat2, double lng2) {
  const earth = 6371008.8;
  final p1 = lat1 * math.pi / 180;
  final p2 = lat2 * math.pi / 180;
  final dp = p2 - p1;
  final dl = (lng2 - lng1) * math.pi / 180;
  final h = math.sin(dp / 2) * math.sin(dp / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * earth * math.asin(math.sqrt(h.clamp(0.0, 1.0)));
}

/// Returns local east/west offset along and cross the left fix heading.
(double, double) _alongCross(ReplayFix left, ReplayFix right) {
  final scale = math.pi / 180 * 6371008.8;
  final east = (right.longitude - left.longitude) *
      scale *
      math.cos(left.latitude * math.pi / 180);
  final north = (right.latitude - left.latitude) * scale;
  final heading = (left.headingDegrees ?? 0) * math.pi / 180;
  return (
    east * math.sin(heading) + north * math.cos(heading),
    east * math.cos(heading) - north * math.sin(heading)
  );
}
