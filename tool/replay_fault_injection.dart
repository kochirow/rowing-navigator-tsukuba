import 'dart:convert';
import 'dart:math';

import 'replay_estimator.dart';

class FaultRecipe {
  final int seed;
  final List<Map<String, dynamic>> transforms;
  const FaultRecipe({required this.seed, required this.transforms});

  factory FaultRecipe.fromJson(Map<String, dynamic> json) => FaultRecipe(
        seed: (json['seed'] as num?)?.toInt() ?? 0,
        transforms: (json['transforms'] as List? ?? const [])
            .map((raw) => Map<String, dynamic>.from(raw as Map))
            .toList(growable: false),
      );

  String toCanonicalJson() => jsonEncode({
        'recipeVersion': 1,
        'seed': seed,
        'transforms': transforms,
      });
}

class InjectedFix {
  final ReplayFix fix;
  final DateTime arrival;
  final bool remoteSpeedMissing;
  const InjectedFix(
      {required this.fix,
      required this.arrival,
      this.remoteSpeedMissing = false});

  InjectedFix copyWith(
          {ReplayFix? fix, DateTime? arrival, bool? remoteSpeedMissing}) =>
      InjectedFix(
          fix: fix ?? this.fix,
          arrival: arrival ?? this.arrival,
          remoteSpeedMissing: remoteSpeedMissing ?? this.remoteSpeedMissing);
}

ReplayFix _copy(ReplayFix source,
        {DateTime? timestamp,
        double? latitude,
        double? longitude,
        double? accuracy,
        double? heading,
        double? speed}) =>
    ReplayFix(
      timestamp: timestamp ?? source.timestamp,
      latitude: latitude ?? source.latitude,
      longitude: longitude ?? source.longitude,
      accuracyMeters: accuracy ?? source.accuracyMeters,
      speedMetersPerSecond: speed ?? source.speedMetersPerSecond,
      headingDegrees: heading ?? source.headingDegrees,
      quality: source.quality,
      recordedFilteredLatitude: source.recordedFilteredLatitude,
      recordedFilteredLongitude: source.recordedFilteredLongitude,
    );

/// Applies the complete S1-04 catalog without changing the source log.
List<InjectedFix> injectFaults(List<ReplayFix> input, FaultRecipe recipe) {
  var records = input
      .map((fix) => InjectedFix(fix: fix, arrival: fix.timestamp))
      .toList();
  final random = Random(recipe.seed);
  for (final transform in recipe.transforms) {
    final id = transform['id'] as String?;
    if (id == null) throw FormatException('fault transform without id');
    final start =
        (transform['startSec'] as num?)?.toDouble() ?? double.negativeInfinity;
    final end = (transform['endSec'] as num?)?.toDouble() ?? double.infinity;
    bool selected(InjectedFix record) {
      final seconds = record.fix.timestamp
              .difference(input.first.timestamp)
              .inMilliseconds /
          1000;
      return seconds >= start && seconds <= end;
    }

    switch (id) {
      case 'drop_periodic':
        final every = (transform['every'] as num?)?.toInt() ?? 2;
        records = [
          for (var i = 0; i < records.length; i++)
            if (!selected(records[i]) || i % every != 0) records[i]
        ];
      case 'drop_burst':
        final at = (transform['atSec'] as num?)?.toDouble() ?? start;
        final duration = (transform['durationSec'] as num?)?.toDouble() ?? 3;
        records = records.where((record) {
          final seconds = record.fix.timestamp
                  .difference(input.first.timestamp)
                  .inMilliseconds /
              1000;
          return seconds < at || seconds >= at + duration;
        }).toList();
      case 'delivery_delay':
        final delay = (transform['delaySec'] as num?)?.toDouble() ?? 1;
        records = records
            .map((r) => selected(r)
                ? r.copyWith(
                    arrival: r.arrival
                        .add(Duration(milliseconds: (delay * 1000).round())))
                : r)
            .toList();
      case 'batch_delivery':
        final size = (transform['batchSize'] as num?)?.toInt() ?? 2;
        for (var i = 0; i < records.length; i += size) {
          final batch = records.skip(i).take(size).where(selected).toList();
          if (batch.isEmpty) {
            continue;
          }
          final at = batch.last.arrival;
          for (final entry in batch) {
            final index = records.indexOf(entry);
            records[index] = entry.copyWith(arrival: at);
          }
        }
      case 'duplicate_fix':
        final count = (transform['count'] as num?)?.toInt() ?? 1;
        records = records
            .expand((r) => selected(r) ? [r, ...List.filled(count, r)] : [r])
            .toList();
      case 'out_of_order':
        final size = (transform['blockSize'] as num?)?.toInt() ?? 2;
        for (var i = 0; i + size <= records.length; i += size) {
          final block = records.sublist(i, i + size);
          if (block.any(selected)) {
            records.replaceRange(i, i + size, block.reversed);
          }
        }
      case 'stale_replay':
        final delay = (transform['delaySec'] as num?)?.toDouble() ?? 2;
        records = records
            .map((r) => selected(r)
                ? r.copyWith(
                    arrival: r.arrival
                        .add(Duration(milliseconds: (delay * 1000).round())))
                : r)
            .toList();
      case 'accuracy_scale':
        final factor = (transform['factor'] as num?)?.toDouble() ?? 2;
        records = records
            .map((r) => selected(r)
                ? r.copyWith(
                    fix: _copy(r.fix, accuracy: r.fix.accuracyMeters * factor))
                : r)
            .toList();
      case 'residual_block':
      case 'bias_ramp':
        final maximum = (transform['meters'] as num?)?.toDouble() ?? 10;
        records = records.map((r) {
          if (!selected(r)) return r;
          final amount =
              id == 'bias_ramp' ? maximum * random.nextDouble() : maximum;
          final deltaLat = amount / 111320;
          return r.copyWith(
              fix: _copy(r.fix, latitude: r.fix.latitude + deltaLat));
        }).toList();
      case 'heading_loss':
        records = records
            .map((r) => selected(r)
                ? r.copyWith(fix: _copy(r.fix, heading: double.nan))
                : r)
            .toList();
      case 'remote_delay':
        final delay = (transform['delaySec'] as num?)?.toDouble() ?? 2;
        records = records
            .map((r) => selected(r)
                ? r.copyWith(
                    arrival: r.arrival
                        .add(Duration(milliseconds: (delay * 1000).round())))
                : r)
            .toList();
      case 'remote_speed_null':
        records = records
            .map((r) => selected(r) ? r.copyWith(remoteSpeedMissing: true) : r)
            .toList();
      default:
        throw FormatException('unknown fault transform: $id');
    }
  }
  return records..sort((a, b) => a.arrival.compareTo(b.arrival));
}
