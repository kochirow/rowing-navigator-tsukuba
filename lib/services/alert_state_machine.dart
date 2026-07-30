import '../models/alert_candidate.dart';

/// Explicit evidence that a detector's complete clear policy was evaluated.
///
/// Missing evidence and [AlertDataQuality.unusable] both mean "unknown", not
/// "safe". Explicit unusable evidence may finish a stale physical alert after
/// three seconds only because the corresponding capability fault remains
/// active. Physical detectors otherwise set [clearConditionsMet] only after
/// their complete exit policy passes.
class AlertClearEvidence {
  final String alertId;
  final String observationId;
  final DateTime evaluatedAt;
  final AlertDataQuality dataQuality;
  final bool clearConditionsMet;

  const AlertClearEvidence({
    required this.alertId,
    required this.observationId,
    required this.evaluatedAt,
    required this.dataQuality,
    required this.clearConditionsMet,
  });

  bool get isUsable => dataQuality != AlertDataQuality.unusable;
}

/// One coherent detector evaluation delivered to the state machine.
class AlertEvaluationBatch {
  final DateTime evaluatedAt;
  final List<AlertCandidate> candidates;
  final List<AlertClearEvidence> clearEvidence;
  final Set<String> retireAlertIds;

  AlertEvaluationBatch({
    required this.evaluatedAt,
    Iterable<AlertCandidate> candidates = const [],
    Iterable<AlertClearEvidence> clearEvidence = const [],
    Iterable<String> retireAlertIds = const [],
  })  : candidates = List.unmodifiable(candidates),
        clearEvidence = List.unmodifiable(clearEvidence),
        retireAlertIds = Set.unmodifiable(retireAlertIds) {
    final candidateIds = <String>{};
    for (final candidate in this.candidates) {
      if (!candidateIds.add(candidate.alertId)) {
        throw ArgumentError('Duplicate candidate ${candidate.alertId}');
      }
    }
    final clearIds = <String>{};
    for (final evidence in this.clearEvidence) {
      if (!clearIds.add(evidence.alertId)) {
        throw ArgumentError('Duplicate clear evidence ${evidence.alertId}');
      }
      if (candidateIds.contains(evidence.alertId)) {
        throw ArgumentError(
          'The same alert cannot be dangerous and clear in one batch: '
          '${evidence.alertId}',
        );
      }
    }
    if (this.retireAlertIds.any(
          (id) => candidateIds.contains(id) || clearIds.contains(id),
        )) {
      throw ArgumentError('A retired alert cannot also be evaluated');
    }
  }
}

class AlertStateView {
  final AlertCandidate candidate;
  final AlertPhase phase;
  final DateTime stateChangedAt;
  final int confirmationObservationCount;
  final bool dataUnknown;

  const AlertStateView({
    required this.candidate,
    required this.phase,
    required this.stateChangedAt,
    required this.confirmationObservationCount,
    required this.dataUnknown,
  });

  bool get isActive =>
      phase == AlertPhase.alerting || phase == AlertPhase.clearing;
}

class AlertTransition {
  final String alertId;
  final AlertPhase from;
  final AlertPhase to;
  final DateTime occurredAt;

  const AlertTransition({
    required this.alertId,
    required this.from,
    required this.to,
    required this.occurredAt,
  });
}

class AlertStateMachineOutput {
  final List<AlertStateView> alerts;
  final List<AlertTransition> transitions;
  final AlertStateView? primaryAlert;

  AlertStateMachineOutput({
    required Iterable<AlertStateView> alerts,
    required Iterable<AlertTransition> transitions,
    required this.primaryAlert,
  })  : alerts = List.unmodifiable(alerts),
        transitions = List.unmodifiable(transitions);

  Iterable<AlertStateView> get activeAlerts =>
      alerts.where((alert) => alert.isActive);

  AlertPhase phaseFor(String alertId) {
    for (final alert in alerts) {
      if (alert.candidate.alertId == alertId) return alert.phase;
    }
    return AlertPhase.safe;
  }
}

/// Deterministic ordering and primary selection for alert candidates.
class AlertCandidateComparator {
  final Duration primaryDeadlineTolerance;

  const AlertCandidateComparator({
    this.primaryDeadlineTolerance = const Duration(seconds: 2),
  });

  int compare(AlertCandidate a, AlertCandidate b) {
    var result = _behaviorBand(a.behavior).compareTo(_behaviorBand(b.behavior));
    if (result != 0) return result;

    result = _boolRank(a.currentOverlap).compareTo(_boolRank(b.currentOverlap));
    if (result != 0) return result;

    // 橋と橋脚が同時に重なったときは、距離やIDに関係なく
    // より具体的な橋脚の表示・音声を優先する。
    result = _bridgePierBridgeOrder(a, b);
    if (result != 0) return result;

    result = _deadlineMicros(a).compareTo(_deadlineMicros(b));
    if (result != 0) return result;

    // カーブと逆走注意が同時に成立する境界では、距離やIDに
    // 左右されず逆走注意を先にする。他カテゴリの順位は変えない。
    result = _reverseCurveOrder(a, b);
    if (result != 0) return result;

    result = _distanceMillimeters(a).compareTo(_distanceMillimeters(b));
    if (result != 0) return result;

    // 利用者向けに段階表示はしないが、同一時間・距離の
    // 内部調停ではdetectorが算出した緊急度を使う。
    result = b.internalPriority.compareTo(a.internalPriority);
    if (result != 0) return result;

    result = _qualityRank(a.dataQuality).compareTo(_qualityRank(b.dataQuality));
    if (result != 0) return result;

    return a.alertId.compareTo(b.alertId);
  }

  List<AlertCandidate> ordered(Iterable<AlertCandidate> candidates) {
    final result = List<AlertCandidate>.of(candidates);
    result.sort(compare);
    return List.unmodifiable(result);
  }

  /// Selects a primary without making sort order depend on input order.
  ///
  /// The current primary is retained only when behavior, overlap, and quality
  /// match the best challenger and its deadline is no more than two seconds
  /// later. A substantially more urgent alert always preempts the lock.
  AlertCandidate? selectPrimary(
    Iterable<AlertCandidate> candidates, {
    String? currentPrimaryAlertId,
  }) {
    final sorted = ordered(candidates);
    if (sorted.isEmpty) return null;
    final best = sorted.first;
    if (currentPrimaryAlertId == null ||
        best.alertId == currentPrimaryAlertId) {
      return best;
    }

    AlertCandidate? current;
    for (final candidate in sorted) {
      if (candidate.alertId == currentPrimaryAlertId) {
        current = candidate;
        break;
      }
    }
    if (current == null || !_lockCompatible(current, best)) return best;

    // 逆走注意はカーブ案内より常に優先する。通常の2秒ロックで
    // 割込みが遅れると、同時区域でカーブ音が鳴り続けてしまう。
    if (_reverseMustPreemptCurve(current, best)) return best;
    if (_bridgePierMustPreemptBridge(current, best)) return best;

    final currentDeadline = _deadlineMicros(current);
    final bestDeadline = _deadlineMicros(best);
    if (currentDeadline == _infiniteDeadline) return best;
    final tolerance = primaryDeadlineTolerance.inMicroseconds;
    return currentDeadline <= bestDeadline + tolerance ? current : best;
  }

  /// 音声アセットを持つ候補だけを対象に、持続音の対象を選ぶ。
  ///
  /// 表示のprimaryと分けるためだけの入口で、順位付けもロックの挙動も
  /// [selectPrimary] と同じものを使う。無音の system fault
  /// (`operational_coverage_unverified` など)が表示primaryになっても、
  /// 鳴っている音を止めない経路にするために必要。
  AlertCandidate? selectAudioPrimary(
    Iterable<AlertCandidate> candidates, {
    String? currentAudioAlertId,
  }) =>
      selectPrimary(
        candidates.where((candidate) => candidate.audioAsset != null),
        currentPrimaryAlertId: currentAudioAlertId,
      );

  bool _lockCompatible(AlertCandidate current, AlertCandidate challenger) {
    return _behaviorBand(current.behavior) ==
            _behaviorBand(challenger.behavior) &&
        current.currentOverlap == challenger.currentOverlap &&
        current.dataQuality == challenger.dataQuality;
  }

  static bool _reverseMustPreemptCurve(
    AlertCandidate current,
    AlertCandidate challenger,
  ) =>
      current.category == 'curve' && challenger.category == 'reverse';

  static int _reverseCurveOrder(AlertCandidate a, AlertCandidate b) {
    if (a.category == 'reverse' && b.category == 'curve') return -1;
    if (a.category == 'curve' && b.category == 'reverse') return 1;
    return 0;
  }

  static bool _bridgePierMustPreemptBridge(
    AlertCandidate current,
    AlertCandidate challenger,
  ) =>
      current.currentOverlap &&
      challenger.currentOverlap &&
      current.category == 'bridge' &&
      challenger.category == 'bridgePier';

  static int _bridgePierBridgeOrder(AlertCandidate a, AlertCandidate b) {
    if (!a.currentOverlap || !b.currentOverlap) return 0;
    if (a.category == 'bridgePier' && b.category == 'bridge') return -1;
    if (a.category == 'bridge' && b.category == 'bridgePier') return 1;
    return 0;
  }

  static int _behaviorBand(AlertBehavior behavior) => switch (behavior) {
        AlertBehavior.continuousAction => 0,
        AlertBehavior.singleAction => 1,
        AlertBehavior.persistentSystemFault => 2,
        AlertBehavior.entryEvent => 3,
        AlertBehavior.visualOnly => 4,
      };

  static int _boolRank(bool value) => value ? 0 : 1;

  static int _qualityRank(AlertDataQuality quality) => switch (quality) {
        AlertDataQuality.good => 0,
        AlertDataQuality.degraded => 1,
        AlertDataQuality.unusable => 2,
      };

  static const int _infiniteDeadline = 0x7FFFFFFFFFFFFFFF;

  static int _deadlineMicros(AlertCandidate candidate) {
    if (candidate.currentOverlap) return 0;
    final deadline = candidate.actionDeadline;
    if (deadline == null) return _infiniteDeadline;
    return deadline.isNegative ? 0 : deadline.inMicroseconds;
  }

  static int _distanceMillimeters(AlertCandidate candidate) {
    final distance = candidate.distanceMeters;
    if (distance == null || !distance.isFinite) return _infiniteDeadline;
    return (distance.clamp(0, 9000000000) * 1000).round();
  }
}

class AlertStateMachine {
  final Duration startConfirmationDuration;
  final int startConfirmationObservations;
  final Duration immediateActionDeadline;
  final Duration clearConfirmationDuration;
  final int clearConfirmationObservations;
  final Duration degradedClearConfirmationDuration;
  final AlertCandidateComparator comparator;

  final Map<String, _TrackedAlert> _tracked = {};
  DateTime? _lastBatchAt;
  String? _primaryAlertId;

  AlertStateMachine({
    this.startConfirmationDuration = const Duration(seconds: 1),
    this.startConfirmationObservations = 2,
    // 連続音のバンドが7秒になったため、確定待ちの2観測1秒が
    // 「残り2.5秒で現れた脅威」の警告を1.5秒前まで遅らせてしまう。
    // 4秒以内の脅威は初回観測で即警告する。
    this.immediateActionDeadline = const Duration(seconds: 4),
    this.clearConfirmationDuration = const Duration(seconds: 2),
    this.clearConfirmationObservations = 2,
    this.degradedClearConfirmationDuration = const Duration(seconds: 3),
    this.comparator = const AlertCandidateComparator(),
  }) {
    if (startConfirmationObservations < 1) {
      throw ArgumentError.value(
        startConfirmationObservations,
        'startConfirmationObservations',
        'must be at least 1',
      );
    }
    if (clearConfirmationObservations < 1) {
      throw ArgumentError.value(
        clearConfirmationObservations,
        'clearConfirmationObservations',
        'must be at least 1',
      );
    }
  }

  AlertStateMachineOutput process(AlertEvaluationBatch batch) {
    final lastBatchAt = _lastBatchAt;
    if (lastBatchAt != null && batch.evaluatedAt.isBefore(lastBatchAt)) {
      throw StateError('Out-of-order alert evaluation batch');
    }
    _lastBatchAt = batch.evaluatedAt;

    final transitions = <AlertTransition>[];
    for (final alertId in batch.retireAlertIds) {
      final retired = _tracked.remove(alertId);
      if (retired == null) continue;
      transitions.add(AlertTransition(
        alertId: alertId,
        from: retired.phase,
        to: AlertPhase.safe,
        occurredAt: batch.evaluatedAt,
      ));
      if (_primaryAlertId == alertId) _primaryAlertId = null;
    }
    final candidateById = {
      for (final candidate in batch.candidates) candidate.alertId: candidate,
    };
    final clearById = {
      for (final evidence in batch.clearEvidence) evidence.alertId: evidence,
    };
    final ids = <String>{
      ..._tracked.keys,
      ...candidateById.keys,
      ...clearById.keys,
    };

    for (final id in ids) {
      final tracked = _tracked[id];
      final candidate = candidateById[id];
      final clear = clearById[id];

      if (candidate != null) {
        _applyDanger(candidate, tracked, transitions);
      } else if (tracked != null) {
        _applyNonDanger(tracked, clear, transitions);
      }
    }

    final activeCandidates = _tracked.values
        .where((tracked) =>
            tracked.phase == AlertPhase.alerting ||
            tracked.phase == AlertPhase.clearing)
        .map((tracked) => tracked.candidate);
    final primary = comparator.selectPrimary(
      activeCandidates,
      currentPrimaryAlertId: _primaryAlertId,
    );
    _primaryAlertId = primary?.alertId;

    final alerts = _tracked.values.map((tracked) => tracked.toView()).toList()
      ..sort((a, b) => comparator.compare(a.candidate, b.candidate));
    AlertStateView? primaryView;
    if (primary != null) {
      primaryView = alerts.firstWhere(
        (alert) => alert.candidate.alertId == primary.alertId,
      );
    }

    return AlertStateMachineOutput(
      alerts: alerts,
      transitions: transitions,
      primaryAlert: primaryView,
    );
  }

  void _applyDanger(
    AlertCandidate candidate,
    _TrackedAlert? tracked,
    List<AlertTransition> transitions,
  ) {
    if (tracked == null) {
      final immediate = _isImmediate(candidate);
      final phase = immediate ? AlertPhase.alerting : AlertPhase.candidate;
      _tracked[candidate.alertId] = _TrackedAlert(
        candidate: candidate,
        phase: phase,
        stateChangedAt: candidate.evaluatedAt,
        dangerConfirmationStartedAt: candidate.evaluatedAt,
        dangerObservationCount: 1,
        lastDangerObservationId: candidate.observationId,
        lastDangerObservationAt: candidate.evaluatedAt,
      );
      transitions.add(AlertTransition(
        alertId: candidate.alertId,
        from: AlertPhase.safe,
        to: phase,
        occurredAt: candidate.evaluatedAt,
      ));
      return;
    }

    final previousPhase = tracked.phase;
    tracked
      ..candidate = candidate
      ..dataUnknown = false
      ..clearConfirmationStartedAt = null
      ..clearObservationCount = 0
      ..clearDataQuality = null
      ..lastClearObservationId = null
      ..lastClearObservationAt = null;

    if (previousPhase == AlertPhase.clearing) {
      tracked
        ..phase = AlertPhase.alerting
        ..stateChangedAt = candidate.evaluatedAt;
      transitions.add(AlertTransition(
        alertId: candidate.alertId,
        from: AlertPhase.clearing,
        to: AlertPhase.alerting,
        occurredAt: candidate.evaluatedAt,
      ));
      return;
    }

    if (previousPhase == AlertPhase.alerting) return;

    if (_isImmediate(candidate)) {
      tracked
        ..phase = AlertPhase.alerting
        ..stateChangedAt = candidate.evaluatedAt;
      transitions.add(AlertTransition(
        alertId: candidate.alertId,
        from: AlertPhase.candidate,
        to: AlertPhase.alerting,
        occurredAt: candidate.evaluatedAt,
      ));
      return;
    }

    if (_isNewObservation(
      id: candidate.observationId,
      at: candidate.evaluatedAt,
      lastId: tracked.lastDangerObservationId,
      lastAt: tracked.lastDangerObservationAt,
    )) {
      tracked
        ..dangerObservationCount += 1
        ..lastDangerObservationId = candidate.observationId
        ..lastDangerObservationAt = candidate.evaluatedAt;
      tracked.dangerConfirmationStartedAt ??= candidate.evaluatedAt;
    }

    final startedAt = tracked.dangerConfirmationStartedAt;
    if (tracked.dangerObservationCount >= startConfirmationObservations &&
        startedAt != null &&
        candidate.evaluatedAt.difference(startedAt) >=
            startConfirmationDuration) {
      tracked
        ..phase = AlertPhase.alerting
        ..stateChangedAt = candidate.evaluatedAt;
      transitions.add(AlertTransition(
        alertId: candidate.alertId,
        from: AlertPhase.candidate,
        to: AlertPhase.alerting,
        occurredAt: candidate.evaluatedAt,
      ));
    }
  }

  void _applyNonDanger(
    _TrackedAlert tracked,
    AlertClearEvidence? clear,
    List<AlertTransition> transitions,
  ) {
    if (clear == null) {
      tracked.dataUnknown = true;
      if (tracked.phase == AlertPhase.clearing) {
        tracked.clearDataQuality = _worseQuality(
          tracked.clearDataQuality,
          AlertDataQuality.unusable,
        );
      }
      return;
    }

    if (!clear.isUsable) {
      // Explicit unusable evidence switches to the three-second ceiling.
      // The corresponding GPS/track/pipeline fault remains as its own alert,
      // so the stale physical warning can finish without showing all-clear.
      tracked.dataUnknown = true;
      if (tracked.phase == AlertPhase.alerting) {
        tracked
          ..phase = AlertPhase.clearing
          ..stateChangedAt = clear.evaluatedAt
          ..clearConfirmationStartedAt = clear.evaluatedAt
          ..clearObservationCount = 0
          ..clearDataQuality = AlertDataQuality.unusable
          ..lastClearObservationId = null
          ..lastClearObservationAt = null;
        transitions.add(AlertTransition(
          alertId: tracked.candidate.alertId,
          from: AlertPhase.alerting,
          to: AlertPhase.clearing,
          occurredAt: clear.evaluatedAt,
        ));
        return;
      }
      if (tracked.phase == AlertPhase.clearing) {
        tracked.clearDataQuality = _worseQuality(
          tracked.clearDataQuality,
          AlertDataQuality.unusable,
        );
        _completeClearIfReady(
          tracked,
          clear.evaluatedAt,
          transitions,
          requireObservations: false,
        );
      }
      return;
    }

    tracked.dataUnknown = false;
    if (!clear.clearConditionsMet) {
      tracked
        ..dangerConfirmationStartedAt = null
        ..dangerObservationCount = 0
        ..clearConfirmationStartedAt = null
        ..clearObservationCount = 0
        ..clearDataQuality = null
        ..lastClearObservationId = null
        ..lastClearObservationAt = null;
      if (tracked.phase == AlertPhase.clearing) {
        tracked
          ..phase = AlertPhase.alerting
          ..stateChangedAt = clear.evaluatedAt;
        transitions.add(AlertTransition(
          alertId: tracked.candidate.alertId,
          from: AlertPhase.clearing,
          to: AlertPhase.alerting,
          occurredAt: clear.evaluatedAt,
        ));
      }
      return;
    }

    if (tracked.phase == AlertPhase.candidate) {
      _tracked.remove(tracked.candidate.alertId);
      transitions.add(AlertTransition(
        alertId: tracked.candidate.alertId,
        from: AlertPhase.candidate,
        to: AlertPhase.safe,
        occurredAt: clear.evaluatedAt,
      ));
      return;
    }

    if (tracked.phase == AlertPhase.alerting) {
      tracked
        ..phase = AlertPhase.clearing
        ..stateChangedAt = clear.evaluatedAt
        ..clearConfirmationStartedAt = clear.evaluatedAt
        ..clearObservationCount = 1
        ..clearDataQuality = clear.dataQuality
        ..lastClearObservationId = clear.observationId
        ..lastClearObservationAt = clear.evaluatedAt;
      transitions.add(AlertTransition(
        alertId: tracked.candidate.alertId,
        from: AlertPhase.alerting,
        to: AlertPhase.clearing,
        occurredAt: clear.evaluatedAt,
      ));
      return;
    }

    // Missing data may have occurred during this window. Continue from the
    // original start instead of restarting when quality recovers.
    if (tracked.clearConfirmationStartedAt == null) {
      tracked
        ..clearConfirmationStartedAt = clear.evaluatedAt
        ..clearObservationCount = 1
        ..clearDataQuality = clear.dataQuality
        ..lastClearObservationId = clear.observationId
        ..lastClearObservationAt = clear.evaluatedAt;
      return;
    }

    tracked.clearDataQuality = _worseQuality(
      tracked.clearDataQuality,
      clear.dataQuality,
    );

    if (_isNewObservation(
      id: clear.observationId,
      at: clear.evaluatedAt,
      lastId: tracked.lastClearObservationId,
      lastAt: tracked.lastClearObservationAt,
    )) {
      tracked
        ..clearObservationCount += 1
        ..lastClearObservationId = clear.observationId
        ..lastClearObservationAt = clear.evaluatedAt;
    }

    _completeClearIfReady(tracked, clear.evaluatedAt, transitions);
  }

  void _completeClearIfReady(
    _TrackedAlert tracked,
    DateTime evaluatedAt,
    List<AlertTransition> transitions, {
    bool requireObservations = true,
  }) {
    final policy = _clearPolicy(tracked.clearDataQuality);
    final startedAt = tracked.clearConfirmationStartedAt;
    if ((!requireObservations ||
            tracked.clearObservationCount >= policy.observations) &&
        startedAt != null &&
        evaluatedAt.difference(startedAt) >= policy.duration) {
      _tracked.remove(tracked.candidate.alertId);
      transitions.add(AlertTransition(
        alertId: tracked.candidate.alertId,
        from: AlertPhase.clearing,
        to: AlertPhase.safe,
        occurredAt: evaluatedAt,
      ));
    }
  }

  _ClearConfirmationPolicy _clearPolicy(AlertDataQuality? worstQuality) {
    final duration = worstQuality == AlertDataQuality.good
        ? clearConfirmationDuration
        : degradedClearConfirmationDuration;
    return _ClearConfirmationPolicy(
      duration,
      clearConfirmationObservations,
    );
  }

  static AlertDataQuality _worseQuality(
    AlertDataQuality? current,
    AlertDataQuality next,
  ) {
    if (current == null) return next;
    return current.index >= next.index ? current : next;
  }

  bool _isImmediate(AlertCandidate candidate) {
    if (candidate.currentOverlap) return true;
    final deadline = candidate.actionDeadline;
    return deadline != null && deadline <= immediateActionDeadline;
  }

  static bool _isNewObservation({
    required String id,
    required DateTime at,
    required String? lastId,
    required DateTime? lastAt,
  }) {
    return id != lastId && (lastAt == null || at.isAfter(lastAt));
  }
}

class _TrackedAlert {
  AlertCandidate candidate;
  AlertPhase phase;
  DateTime stateChangedAt;
  DateTime? dangerConfirmationStartedAt;
  int dangerObservationCount;
  String? lastDangerObservationId;
  DateTime? lastDangerObservationAt;
  DateTime? clearConfirmationStartedAt;
  int clearObservationCount;
  AlertDataQuality? clearDataQuality;
  String? lastClearObservationId;
  DateTime? lastClearObservationAt;
  bool dataUnknown;

  _TrackedAlert({
    required this.candidate,
    required this.phase,
    required this.stateChangedAt,
    required this.dangerConfirmationStartedAt,
    required this.dangerObservationCount,
    required this.lastDangerObservationId,
    required this.lastDangerObservationAt,
  })  : clearConfirmationStartedAt = null,
        clearObservationCount = 0,
        clearDataQuality = null,
        lastClearObservationId = null,
        lastClearObservationAt = null,
        dataUnknown = false;

  AlertStateView toView() => AlertStateView(
        candidate: candidate,
        phase: phase,
        stateChangedAt: stateChangedAt,
        confirmationObservationCount: phase == AlertPhase.candidate
            ? dangerObservationCount
            : phase == AlertPhase.clearing
                ? clearObservationCount
                : 0,
        dataUnknown: dataUnknown,
      );
}

class _ClearConfirmationPolicy {
  final Duration duration;
  final int observations;

  const _ClearConfirmationPolicy(this.duration, this.observations);
}
