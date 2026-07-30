/// How an alert is presented while its underlying condition exists.
enum AlertBehavior {
  /// A physical hazard that needs an immediate check or evasive action.
  continuousAction,

  /// A short action warning played once while the same episode persists.
  singleAction,

  /// A one-shot notification when entering a guidance area.
  entryEvent,

  /// An early caution that remains visible without starting warning audio.
  visualOnly,

  /// A fault that persists while a safety capability is unavailable.
  persistentSystemFault,
}

/// Quality of the data used to produce an alert candidate.
enum AlertDataQuality {
  good,
  degraded,
  unusable,
}

/// Lifecycle shared by all alert categories.
enum AlertPhase {
  safe,
  candidate,
  alerting,
  clearing,
}

/// A detector result before debounce, arbitration, and presentation.
///
/// Instances are immutable. [alertId] and [observationId] intentionally have
/// different roles: the former follows the same hazard across evaluations,
/// while the latter identifies the source observation used by confirmation
/// logic.
class AlertCandidate {
  final String alertId;
  final String detectorId;
  final String category;
  final String? targetId;
  final String? targetSessionId;
  final AlertBehavior behavior;
  final int internalPriority;
  final Duration? actionDeadline;
  final bool currentOverlap;
  final double confidence;
  final AlertDataQuality dataQuality;

  /// Signed distance to the hazard in metres; negative inside a hazard zone.
  ///
  /// A clamped-at-zero distance is not monotonic once the boat enters a zone,
  /// which breaks approach detection while at rest. Keeping the sign preserves
  /// monotonicity; ordering clamps it separately.
  final double? distanceMeters;

  /// Closest predicted clearance between the safety domains in metres (DCPA).
  ///
  /// Zero when the domains intersect. This is the gap between domains, not
  /// between hulls, so the physical separation is larger.
  final double? separationMeters;

  /// 自艇針路から見た脅威の相対方位 [度](-180〜180、正が右舷側)。
  ///
  /// 表示で「どちらを振り向くか」を伝えるためだけに使い、判定には使わない。
  /// 自艇の方位が信頼できないとき(低速・回頭中)は検出側が null にする。
  final double? relativeBearingDegrees;
  final DateTime evaluatedAt;
  final String observationId;
  final List<String> reasonCodes;
  final String? audioAsset;
  final String? audioEventId;

  /// Whether this is a future physical intersection rather than a hazard that
  /// is already affecting the current position.
  ///
  /// System faults can also carry a zero deadline, so behavior is part of the
  /// distinction. Keeping the decision here prevents UI code from guessing
  /// from category names or display text.
  bool get isPredicted =>
      (behavior == AlertBehavior.continuousAction ||
          behavior == AlertBehavior.singleAction ||
          behavior == AlertBehavior.visualOnly) &&
      !currentOverlap &&
      actionDeadline != null;

  AlertCandidate({
    required this.alertId,
    required this.detectorId,
    required this.category,
    required this.behavior,
    required this.evaluatedAt,
    required this.observationId,
    this.targetId,
    this.targetSessionId,
    this.internalPriority = 0,
    this.actionDeadline,
    this.currentOverlap = false,
    this.confidence = 1,
    this.dataQuality = AlertDataQuality.good,
    this.distanceMeters,
    this.separationMeters,
    this.relativeBearingDegrees,
    List<String> reasonCodes = const [],
    this.audioAsset,
    this.audioEventId,
  }) : reasonCodes = List.unmodifiable(reasonCodes) {
    _requireNonEmpty(alertId, 'alertId');
    _requireNonEmpty(detectorId, 'detectorId');
    _requireNonEmpty(category, 'category');
    _requireNonEmpty(observationId, 'observationId');
    if (!confidence.isFinite || confidence < 0 || confidence > 1) {
      throw ArgumentError.value(
        confidence,
        'confidence',
        'must be finite and between 0 and 1',
      );
    }
    if (distanceMeters != null && !distanceMeters!.isFinite) {
      throw ArgumentError.value(
        distanceMeters,
        'distanceMeters',
        'must be null or finite (negative means inside the hazard zone)',
      );
    }
    if (separationMeters != null &&
        (!separationMeters!.isFinite || separationMeters! < 0)) {
      throw ArgumentError.value(
        separationMeters,
        'separationMeters',
        'must be null or a finite non-negative value',
      );
    }
  }

  /// Creates a candidate whose ID is based only on stable detector/target
  /// identity, never on display text, list order, or an audio file name.
  factory AlertCandidate.stable({
    required String detectorId,
    required String category,
    required AlertBehavior behavior,
    required DateTime evaluatedAt,
    required String observationId,
    String? targetId,
    String? targetSessionId,
    int internalPriority = 0,
    Duration? actionDeadline,
    bool currentOverlap = false,
    double confidence = 1,
    AlertDataQuality dataQuality = AlertDataQuality.good,
    double? distanceMeters,
    double? separationMeters,
    double? relativeBearingDegrees,
    List<String> reasonCodes = const [],
    String? audioAsset,
    String? audioEventId,
  }) {
    return AlertCandidate(
      alertId: buildStableAlertId(
        detectorId: detectorId,
        category: category,
        targetId: targetId,
        targetSessionId: targetSessionId,
      ),
      detectorId: detectorId,
      category: category,
      targetId: targetId,
      targetSessionId: targetSessionId,
      behavior: behavior,
      internalPriority: internalPriority,
      actionDeadline: actionDeadline,
      currentOverlap: currentOverlap,
      confidence: confidence,
      dataQuality: dataQuality,
      distanceMeters: distanceMeters,
      separationMeters: separationMeters,
      relativeBearingDegrees: relativeBearingDegrees,
      evaluatedAt: evaluatedAt,
      observationId: observationId,
      reasonCodes: reasonCodes,
      audioAsset: audioAsset,
      audioEventId: audioEventId,
    );
  }

  /// Stable identity format defined by the warning-system design.
  static String buildStableAlertId({
    required String detectorId,
    required String category,
    String? targetId,
    String? targetSessionId,
  }) {
    _requireNonEmpty(detectorId, 'detectorId');
    _requireNonEmpty(category, 'category');
    if (targetId != null) _requireNonEmpty(targetId, 'targetId');
    if (targetSessionId != null) {
      _requireNonEmpty(targetSessionId, 'targetSessionId');
    }

    String component(String? value) =>
        value == null ? '-' : 'v:${Uri.encodeComponent(value)}';

    return '${Uri.encodeComponent(detectorId)}/'
        '${Uri.encodeComponent(category)}/'
        '${component(targetId)}/'
        '${component(targetSessionId)}';
  }

  AlertCandidate copyWith({
    AlertBehavior? behavior,
    Duration? actionDeadline,
    bool clearActionDeadline = false,
    bool? currentOverlap,
    double? confidence,
    AlertDataQuality? dataQuality,
    double? distanceMeters,
    bool clearDistanceMeters = false,
    double? separationMeters,
    double? relativeBearingDegrees,
    DateTime? evaluatedAt,
    String? observationId,
    List<String>? reasonCodes,
    String? audioAsset,
    bool clearAudioAsset = false,
    String? audioEventId,
    bool clearAudioEventId = false,
  }) {
    return AlertCandidate(
      alertId: alertId,
      detectorId: detectorId,
      category: category,
      targetId: targetId,
      targetSessionId: targetSessionId,
      behavior: behavior ?? this.behavior,
      internalPriority: internalPriority,
      actionDeadline:
          clearActionDeadline ? null : (actionDeadline ?? this.actionDeadline),
      currentOverlap: currentOverlap ?? this.currentOverlap,
      confidence: confidence ?? this.confidence,
      dataQuality: dataQuality ?? this.dataQuality,
      distanceMeters:
          clearDistanceMeters ? null : (distanceMeters ?? this.distanceMeters),
      separationMeters: separationMeters ?? this.separationMeters,
      relativeBearingDegrees:
          relativeBearingDegrees ?? this.relativeBearingDegrees,
      evaluatedAt: evaluatedAt ?? this.evaluatedAt,
      observationId: observationId ?? this.observationId,
      reasonCodes: reasonCodes ?? this.reasonCodes,
      audioAsset: clearAudioAsset ? null : (audioAsset ?? this.audioAsset),
      audioEventId:
          clearAudioEventId ? null : (audioEventId ?? this.audioEventId),
    );
  }

  static void _requireNonEmpty(String value, String name) {
    if (value.trim().isEmpty) {
      throw ArgumentError.value(value, name, 'must not be empty');
    }
  }
}
