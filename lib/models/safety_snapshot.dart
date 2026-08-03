import 'dart:collection';

import 'alert_candidate.dart';

enum SafetyRunMode {
  stopped,
  runningFull,
  runningDegraded,
  unavailable,
}

class CapabilitySnapshot {
  final bool gpsUsable;
  final bool staticProfileUsable;
  final bool audioUsable;
  final bool dynamicReceiveUsable;
  final bool positionSharingUsable;
  final bool pipelineResponsive;

  const CapabilitySnapshot({
    required this.gpsUsable,
    required this.staticProfileUsable,
    required this.audioUsable,
    this.dynamicReceiveUsable = true,
    this.positionSharingUsable = true,
    this.pipelineResponsive = true,
  });
}

class DetectorHealth {
  final String detectorId;
  final AlertDataQuality quality;
  final DateTime? lastSuccessAt;
  final List<String> reasonCodes;

  DetectorHealth({
    required this.detectorId,
    required this.quality,
    this.lastSuccessAt,
    List<String> reasonCodes = const [],
  }) : reasonCodes = List.unmodifiable(reasonCodes) {
    if (detectorId.trim().isEmpty) {
      throw ArgumentError.value(detectorId, 'detectorId', 'must not be empty');
    }
  }
}

class DetectorHealthSnapshot {
  final Map<String, DetectorHealth> byDetectorId;

  DetectorHealthSnapshot(Iterable<DetectorHealth> health)
      : byDetectorId = UnmodifiableMapView({
          for (final item in health) item.detectorId: item,
        });

  const DetectorHealthSnapshot.empty() : byDetectorId = const {};
}

class ActiveAlert {
  final AlertCandidate candidate;
  final AlertPhase phase;
  final bool dataUnknown;

  const ActiveAlert({
    required this.candidate,
    required this.phase,
    this.dataUnknown = false,
  }) : assert(
          phase == AlertPhase.alerting || phase == AlertPhase.clearing,
          'Only alerting and clearing alerts are active',
        );
}

enum AudioDirectiveMode { loop, playOnce }

class AudioDirective {
  final String alertId;
  final String asset;
  final AudioDirectiveMode mode;
  final String? eventId;

  const AudioDirective({
    required this.alertId,
    required this.asset,
    required this.mode,
    this.eventId,
  });
}

/// 持続音とは別チャンネルで1回だけ鳴らす合図。
///
/// 音声チャンネルが持続音1本しか無いと、岸の連続音が続いている間、
/// 橋・カーブ・逆走の単発合図が永久に鳴れない
/// (実機ログで逆走・カーブは検知16回・10回に対して一度も鳴らなかった)。
/// 単発合図は元々レート制限されている(区域進入1回 + 再武装、
/// 橋は sourceId 集約で1通過1回)ため、総量は増えない。
class AudioCue {
  final String alertId;
  final String asset;

  /// 消費側の重複排除キー。同じ eventId は二度と出さない。
  final String eventId;
  final String category;

  const AudioCue({
    required this.alertId,
    required this.asset,
    required this.eventId,
    required this.category,
  });
}

class VisualDirective {
  final List<String> orderedAlertIds;

  VisualDirective(Iterable<String> orderedAlertIds)
      : orderedAlertIds = List.unmodifiable(orderedAlertIds);

  const VisualDirective.empty() : orderedAlertIds = const [];
}

/// Atomic, immutable output consumed by UI, audio, haptics, and logging.
class SafetySnapshot {
  final String sessionId;
  final int sessionGeneration;
  final int revision;
  final DateTime evaluatedAt;
  final SafetyRunMode runMode;
  final CapabilitySnapshot capabilities;
  final List<ActiveAlert> activeAlerts;
  final DetectorHealthSnapshot health;
  final String? primaryAlertId;

  /// 持続音(loop/periodic)と単発音の1本だけの対象。
  ///
  /// 表示の [primaryAlertId] とは独立に選ぶ。無音の system fault が
  /// 表示primaryになっても、鳴っている音を止めないようにするため。
  final AudioDirective? audioDirective;

  /// 持続音とは別チャンネルで1回だけ鳴らす合図の一覧。
  final List<AudioCue> oneShotAudioCues;
  final VisualDirective visualDirective;

  SafetySnapshot({
    required this.sessionId,
    required this.sessionGeneration,
    required this.revision,
    required this.evaluatedAt,
    required this.runMode,
    required this.capabilities,
    required Iterable<ActiveAlert> activeAlerts,
    required this.health,
    required this.visualDirective,
    this.primaryAlertId,
    this.audioDirective,
    Iterable<AudioCue> oneShotAudioCues = const [],
  })  : activeAlerts = List.unmodifiable(activeAlerts),
        oneShotAudioCues = List.unmodifiable(oneShotAudioCues) {
    if (sessionId.trim().isEmpty) {
      throw ArgumentError.value(sessionId, 'sessionId', 'must not be empty');
    }
    if (sessionGeneration < 0) {
      throw ArgumentError.value(
        sessionGeneration,
        'sessionGeneration',
        'must not be negative',
      );
    }
    if (revision < 0) {
      throw ArgumentError.value(revision, 'revision', 'must not be negative');
    }
    if (primaryAlertId != null &&
        !this.activeAlerts.any(
              (alert) => alert.candidate.alertId == primaryAlertId,
            )) {
      throw ArgumentError.value(
        primaryAlertId,
        'primaryAlertId',
        'must identify an active alert',
      );
    }
  }

  /// True only when this snapshot may atomically replace [other].
  bool supersedes(SafetySnapshot other) {
    if (sessionGeneration != other.sessionGeneration) {
      return sessionGeneration > other.sessionGeneration;
    }
    if (sessionId != other.sessionId) return false;
    return revision > other.revision;
  }
}

/// Small consumer-side helper that rejects stale or duplicate revisions.
class SafetySnapshotGate {
  SafetySnapshot? _latest;

  SafetySnapshot? get latest => _latest;

  bool accept(SafetySnapshot snapshot) {
    final previous = _latest;
    if (previous != null && !snapshot.supersedes(previous)) return false;
    _latest = snapshot;
    return true;
  }
}
