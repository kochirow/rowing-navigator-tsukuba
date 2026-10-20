import '../models/protection_budget.dart';

enum ContractSeverity { violation, warning }

class ContractObservation {
  final Duration elapsed;
  final DateTime at;
  final DateTime? acceptedFixTimestamp;
  final DateTime? previousAcceptedFixTimestamp;
  final double? protectionRadiusMeters;
  final bool fixUpdatedThisTick;
  final double? separationScore;
  final String? integrityState;
  final String? category;
  final double? remoteSpeedMetersPerSecond;
  final String? suppressionReason;
  final String? urgency;
  final String? episodeKey;
  final bool audioRepeated;
  final bool urgencyWorsened;
  final ProtectionBudget? budget;
  final ProtectionBudget? previousBudget;

  const ContractObservation({
    required this.elapsed,
    required this.at,
    this.acceptedFixTimestamp,
    this.previousAcceptedFixTimestamp,
    this.protectionRadiusMeters,
    this.fixUpdatedThisTick = false,
    this.separationScore,
    this.integrityState,
    this.category,
    this.remoteSpeedMetersPerSecond,
    this.suppressionReason,
    this.urgency,
    this.episodeKey,
    this.audioRepeated = false,
    this.urgencyWorsened = false,
    this.budget,
    this.previousBudget,
  });
}

class ContractViolation {
  final String contractId;
  final ContractSeverity severity;
  final Duration elapsed;
  final String detail;

  const ContractViolation({
    required this.contractId,
    required this.severity,
    required this.elapsed,
    required this.detail,
  });
}

/// 再生・単体テスト・shadow解析で共用する、安全契約の検査器。
/// 本番の提示や判定を変更しない。
class SafetyContractMonitor {
  final double separationLimit;
  final Duration separationConfirmDuration;
  final Duration separationResponseDeadline;
  final Duration integrityRecoveryDuration;
  final List<ContractViolation> _violations = [];
  Duration? _separationExceededSince;
  Duration? _fallbackSince;
  double? _lastProtectionRadius;

  SafetyContractMonitor({
    this.separationLimit = 1,
    this.separationConfirmDuration = const Duration(seconds: 2),
    this.separationResponseDeadline = const Duration(seconds: 1),
    this.integrityRecoveryDuration = const Duration(seconds: 3),
  });

  List<ContractViolation> get violations => List.unmodifiable(_violations);

  void reset() {
    _violations.clear();
    _separationExceededSince = null;
    _fallbackSince = null;
    _lastProtectionRadius = null;
  }

  List<ContractViolation> observe(ContractObservation observation) {
    final found = <ContractViolation>[];
    void violate(String id, String detail) {
      final violation = ContractViolation(
        contractId: id,
        severity: ContractSeverity.violation,
        elapsed: observation.elapsed,
        detail: detail,
      );
      found.add(violation);
      _violations.add(violation);
    }

    final accepted = observation.acceptedFixTimestamp;
    final previous = observation.previousAcceptedFixTimestamp;
    if (accepted != null && previous != null && accepted.isBefore(previous)) {
      violate('FIX_TIMESTAMP_MONOTONIC', 'accepted fix timestamp regressed');
    }

    final radius = observation.protectionRadiusMeters;
    if (!observation.fixUpdatedThisTick &&
        radius != null &&
        _lastProtectionRadius != null &&
        radius < _lastProtectionRadius!) {
      violate(
          'PROTECTION_NEVER_SHRINKS_WHILE_STALE', 'radius shrank without fix');
    }
    if (radius != null) _lastProtectionRadius = radius;

    final separation = observation.separationScore;
    if (separation != null && separation > separationLimit) {
      _separationExceededSince ??= observation.elapsed;
      final overdue = observation.elapsed - _separationExceededSince! >=
          separationConfirmDuration + separationResponseDeadline;
      if (overdue && observation.integrityState == 'trusted') {
        violate(
            'INTEGRITY_LEAVES_TRUSTED_ON_SEPARATION', 'separation persisted');
      }
    } else {
      _separationExceededSince = null;
    }
    if (observation.integrityState != null &&
        observation.integrityState != 'trusted') {
      _fallbackSince ??= observation.elapsed;
    } else if (observation.integrityState == 'trusted' &&
        _fallbackSince != null) {
      if (observation.elapsed - _fallbackSince! < integrityRecoveryDuration) {
        violate(
          'INTEGRITY_NO_PREMATURE_TRUST',
          'trusted before recovery duration elapsed',
        );
      } else {
        _fallbackSince = null;
      }
    }

    if (observation.category == 'other_boat' &&
        observation.remoteSpeedMetersPerSecond == null &&
        observation.suppressionReason == 'at_rest') {
      violate(
          'OTHER_BOAT_NOT_SILENCED_ON_UNKNOWN_SPEED', 'remote speed unknown');
    }
    if (observation.urgency == 'urgent' &&
        const {'low_speed', 'mooring', 'stable_stop'}
            .contains(observation.suppressionReason)) {
      violate(
          'URGENT_NOT_SUPPRESSED_BY_LOW_PRIORITY', 'urgent alert suppressed');
    }
    if (observation.episodeKey != null &&
        observation.audioRepeated &&
        !observation.urgencyWorsened) {
      violate('NO_POINTLESS_REPEAT', 'episode repeated without worsening');
    }

    final budget = observation.budget;
    final previousBudget = observation.previousBudget;
    if (budget != null && previousBudget != null) {
      if (budget.fixAgeMotionMeters < previousBudget.fixAgeMotionMeters) {
        violate('BUDGET_MONOTONIC_FIX_AGE', 'fix age allocation shrank');
      }
      if (budget.remoteLatencyMeters < previousBudget.remoteLatencyMeters) {
        violate('BUDGET_MONOTONIC_REMOTE_AGE', 'remote age allocation shrank');
      }
      if (budget.solutionDisagreementMeters <
          previousBudget.solutionDisagreementMeters) {
        violate('BUDGET_MONOTONIC_SEPARATION', 'solution allocation shrank');
      }
    }
    return found;
  }
}

/// 1秒ウォッチドッグで観測した保護台帳。どの測位から外挿したかを持つ。
class StaleProtectionBudgetSample {
  final DateTime solutionTimestamp;
  final ProtectionBudget budget;

  const StaleProtectionBudgetSample({
    required this.solutionTimestamp,
    required this.budget,
  });
}

/// 台帳の単調性(`BUDGET_MONOTONIC_*`)で比べてよい直前の台帳を返す。
///
/// 単調性は「同じ測位から外挿している間、保護集合が縮まない」という契約である。
/// 新しい測位が届けば台帳は正当に作り直され、縮んでよい。また測位時の台帳
/// (解分離を実測で入れる)と外挿台帳(解分離を持たない)は成分の作り方が違う。
/// 2026-09-26 の実機ログでは、この2つを1つの変数で比べていたため
/// `BUDGET_MONOTONIC_SEPARATION` が測位のたびに誤検出され、毎分記録されていた。
/// 同じ測位から外挿した台帳どうしの場合だけ直前の台帳を返す。
ProtectionBudget? comparablePreviousStaleBudget({
  required StaleProtectionBudgetSample? previous,
  required DateTime? currentSolutionTimestamp,
}) {
  if (previous == null || currentSolutionTimestamp == null) return null;
  if (previous.solutionTimestamp != currentSolutionTimestamp) return null;
  return previous.budget;
}
