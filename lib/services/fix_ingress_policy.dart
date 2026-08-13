import '../config/navigator_config.dart';
import '../models/fix_envelope.dart';

enum FixIngressDecisionKind { accept, duplicate, timestampRegression, reset }

class FixIngressDecision {
  final FixIngressDecisionKind kind;
  final DateTime? previousFixTimestamp;

  const FixIngressDecision(this.kind, {this.previousFixTimestamp});

  bool get accepted =>
      kind == FixIngressDecisionKind.accept ||
      kind == FixIngressDecisionKind.reset;

  FixRejectionReason? get rejectionReason => switch (kind) {
        FixIngressDecisionKind.duplicate => FixRejectionReason.duplicate,
        FixIngressDecisionKind.timestampRegression =>
          FixRejectionReason.timestampRegression,
        _ => null,
      };
}

/// GNSS入口の時刻順序・重複を決める純粋な状態機械。
///
/// 到着時刻は診断だけに使う。採否は常にfix時刻で決めるため、OSのまとめ
/// 配信で新しいfixを失わない。
class FixIngressPolicy {
  final Duration minimumFixInterval;
  final Duration timestampRegressionReset;
  DateTime? _lastAcceptedFixTimestamp;
  Duration? _regressionStartedAt;

  FixIngressPolicy({
    this.minimumFixInterval =
        const Duration(milliseconds: positionMinimumFixIntervalMs),
    this.timestampRegressionReset = fixTimestampRegressionReset,
  });

  DateTime? get lastAcceptedFixTimestamp => _lastAcceptedFixTimestamp;

  FixIngressDecision decide({
    required DateTime fixTimestamp,
    required Duration arrivalMonotonic,
  }) {
    final previous = _lastAcceptedFixTimestamp;
    if (previous == null) {
      _lastAcceptedFixTimestamp = fixTimestamp;
      _regressionStartedAt = null;
      return const FixIngressDecision(FixIngressDecisionKind.accept);
    }
    if (fixTimestamp.isBefore(previous)) {
      _regressionStartedAt ??= arrivalMonotonic;
      if (arrivalMonotonic - _regressionStartedAt! >=
          timestampRegressionReset) {
        _lastAcceptedFixTimestamp = fixTimestamp;
        _regressionStartedAt = null;
        return FixIngressDecision(
          FixIngressDecisionKind.reset,
          previousFixTimestamp: previous,
        );
      }
      return FixIngressDecision(
        FixIngressDecisionKind.timestampRegression,
        previousFixTimestamp: previous,
      );
    }
    _regressionStartedAt = null;
    if (fixTimestamp.difference(previous) < minimumFixInterval) {
      return FixIngressDecision(
        FixIngressDecisionKind.duplicate,
        previousFixTimestamp: previous,
      );
    }
    _lastAcceptedFixTimestamp = fixTimestamp;
    return FixIngressDecision(
      FixIngressDecisionKind.accept,
      previousFixTimestamp: previous,
    );
  }

  void reset() {
    _lastAcceptedFixTimestamp = null;
    _regressionStartedAt = null;
  }
}
