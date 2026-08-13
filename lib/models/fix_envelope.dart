/// 測位入口で観測する、採否を変えない診断用の包み。
enum FixSource { stream, polling }

enum FixRejectionReason {
  duplicate,
  timestampRegression,
  stale,
  invalidCoordinate,
  invalidAccuracy,
  mocked,
  lowAccuracy,
  staleTimestamp,
  nonMonotonic,
  implausibleSpeed,
  supersededInBatch,
  throttleWindow,
  generationMismatch,
}

class FixEnvelope {
  final int sequence;
  final FixSource source;
  final Duration arrivedAtMonotonic;
  final DateTime fixTimestamp;
  final int ageAtArrivalMs;
  final int? deltaFromPreviousFixMs;
  final int? deltaFromPreviousArrivalMs;
  final double accuracyMeters;
  final bool accepted;
  final FixRejectionReason? rejectionReason;

  const FixEnvelope({
    required this.sequence,
    required this.source,
    required this.arrivedAtMonotonic,
    required this.fixTimestamp,
    required this.ageAtArrivalMs,
    this.deltaFromPreviousFixMs,
    this.deltaFromPreviousArrivalMs,
    required this.accuracyMeters,
    required this.accepted,
    this.rejectionReason,
  }) : assert(accepted || rejectionReason != null);

  Map<String, dynamic> toDiagnosticDetails() => {
        'sequence': sequence,
        'source': source.name,
        'arrivedAtMonotonicMs': arrivedAtMonotonic.inMilliseconds,
        'fixTimestamp': fixTimestamp.toUtc().toIso8601String(),
        'ageAtArrivalMs': ageAtArrivalMs,
        if (deltaFromPreviousFixMs != null)
          'deltaFromPreviousFixMs': deltaFromPreviousFixMs,
        if (deltaFromPreviousArrivalMs != null)
          'deltaFromPreviousArrivalMs': deltaFromPreviousArrivalMs,
        'accuracyMeters': accuracyMeters,
        'accepted': accepted,
        if (rejectionReason != null) 'rejectionReason': rejectionReason!.name,
      };
}
