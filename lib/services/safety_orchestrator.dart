import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../config/alert_presentation_config.dart';
import '../config/warning_audio_config.dart';
import '../models/alert_candidate.dart';
import '../models/safety_snapshot.dart';
import '../models/static_obstacle_model.dart';
import '../utils/winding_algorithm.dart';
import 'alert_state_machine.dart';
import 'collision_risk_evaluator_service.dart';
import 'reverse_guidance_debouncer.dart';

class SafetyOrchestratorResult {
  final SafetySnapshot snapshot;
  final AlertStateMachineOutput state;

  const SafetyOrchestratorResult({
    required this.snapshot,
    required this.state,
  });
}

/// 全detectorの候補を1つのFSMに集約し、UIと音声が
/// 同じrevisionを見るための単一writer。
class SafetyOrchestrator {
  final String sessionId;
  final int sessionGeneration;

  /// 桟橋エリア（着艇・係留の水域）のポリゴン。
  ///
  /// **危険区域ではない。** 自艇と相手の双方が低速のときだけ、他艇警告の
  /// 音を落とすためにだけ使う。空でも全機能が従来どおり動く。
  final List<List<LatLng>> mooringAreas;
  // 航行中に利用者が警告時間を変更しても、状態機械を作り直して既存の
  // 警告エピソードを失わないよう、提示設定だけを差し替えられるようにする。
  // 衝突判定結果そのものはこの設定に依存しない。
  AlertPresentationConfig _presentationConfig;
  AlertPresentationConfig get presentationConfig => _presentationConfig;
  final AlertStateMachine _stateMachine;
  int _revision = 0;
  AlertStateMachineOutput? _lastState;
  final Map<String, _LostBoatContext> _lostBoatContexts = {};
  final Map<String, _ThreatPresentationContext> _threatContexts = {};
  final Map<String, _GuidancePresentationContext> _guidanceContexts = {};
  final Map<String, ReverseGuidanceDebouncer> _reverseGuidanceDebouncers = {};
  final Set<String> _stableExistingThreatIds = {};

  /// どちらかのチャンネルで処理済みの音声イベント。alertIdごとに最後の1件。
  ///
  /// 音声イベントIDは単調増加する連番を含むため再利用されない。
  /// 持続音の対象になった単発候補もここへ記録し、あとで対象から外れても
  /// キューで鳴り直さないようにする。
  final Map<String, String> _handledCueEventIdByAlertId = {};

  /// 実際に単発キューへ積んだ音声イベント。alertIdごとに最後の1件。
  ///
  /// 既にキューで鳴らしたものを持続音の対象にすると二重再生になるため、
  /// 持続音の選定から外すのに使う。
  final Map<String, String> _cuedEventIdByAlertId = {};
  DateTime? _lowSpeedStartedAt;
  bool _lowSpeedActive = false;
  DateTime? _lowSpeedAudioMuteStartedAt;
  bool _lowSpeedAudioMuted = false;
  /// 確定待ちを持たない、いまこの評価時点での「休憩とみなせる低速」。
  bool _isAudioMuteSpeedNow = false;
  bool _stableStopped = false;
  int _audioEventSequence = 0;
  String? _audioAlertId;

  SafetyOrchestrator({
    required this.sessionId,
    required this.sessionGeneration,
    this.mooringAreas = const [],
    AlertPresentationConfig presentationConfig = defaultAlertPresentationConfig,
    AlertStateMachine? stateMachine,
  })  : _presentationConfig = presentationConfig,
        _stateMachine = stateMachine ?? AlertStateMachine() {
    if (sessionId.trim().isEmpty) {
      throw ArgumentError.value(sessionId, 'sessionId', 'must not be empty');
    }
  }

  /// 航行中の「本警告・予告」変更を次の評価から使う。
  ///
  /// FSMを新規作成すると、設定変更の瞬間に表示中の警告を安全と誤認して
  /// 解除する経路になり得るため、設定だけを更新する。
  void updatePresentationConfig(AlertPresentationConfig config) {
    _presentationConfig = config;
  }

  Set<String> get activeBoatIds => (_lastState?.activeAlerts ?? const [])
      .map((alert) => alert.candidate)
      .where((candidate) => candidate.category == 'other_boat')
      .map((candidate) => candidate.targetId)
      .whereType<String>()
      .toSet();

  /// 衝突判定とシステム異常を同一バッチで反映する。
  /// [dataQuality]がunusableの場合、消えた物理候補は3秒で
  /// ケイパビリティ異常警告へ切り替える。
  SafetyOrchestratorResult processAssessment({
    required RiskAssessment assessment,
    required DateTime evaluatedAt,
    required CapabilitySnapshot capabilities,
    AlertDataQuality dataQuality = AlertDataQuality.good,
    Iterable<AlertCandidate> systemCandidates = const [],
    Iterable<DetectorHealth> detectorHealth = const [],
    Set<String> unknownBoatIds = const {},
    Set<String> healthyBoatIds = const {},
    Map<String, AlertDataQuality> boatDataQualityById = const {},
    double? ownSpeedMetersPerSecond,
    LatLng? ownPosition,
    Map<String, double?> otherBoatSpeedById = const {},
  }) {
    final observationId = '$sessionId:${_revision + 1}';
    final byId = <String, AlertCandidate>{};
    // 直前まで警告対象だった艇は、freshな受信を確認できない限り
    // 「安全になった」とみなさない。受信層のTTLで一覧から一気に消えた
    // 場合も、通信途絶として保持して物理警告の誤解除を防ぐ。
    final effectiveUnknownBoatIds = <String>{
      ...unknownBoatIds,
      ...activeBoatIds.where((boatId) => !healthyBoatIds.contains(boatId)),
    };

    for (final riskThreat in assessment.threats) {
      final candidate = _fromRiskThreat(
        riskThreat,
        evaluatedAt: evaluatedAt,
        observationId: observationId,
        dataQuality: _combinedQuality(
          dataQuality,
          riskThreat.threat.boatId == null
              ? null
              : boatDataQualityById[riskThreat.threat.boatId],
        ),
      );
      final existing = byId[candidate.alertId];
      if (existing == null || _prefer(candidate, existing)) {
        byId[candidate.alertId] = candidate;
      }
    }
    _applyRiskPresentations(
      byId,
      evaluatedAt: evaluatedAt,
      ownSpeedMetersPerSecond: ownSpeedMetersPerSecond,
      ownPosition: ownPosition,
      otherBoatSpeedById: otherBoatSpeedById,
    );

    final currentBoatTargetIds = byId.values
        .where((candidate) => candidate.category == 'other_boat')
        .map((candidate) => candidate.targetId)
        .whereType<String>()
        .toSet();
    // 途絶後にトラックが復旧した場合、その舟がもう衝突候補で
    // なくても通信途絶状態を解除する。衝突候補だけを復旧根拠に
    // すると、安全な位置で再受信したときに途絶警告が残り続ける。
    for (final targetId in {...currentBoatTargetIds, ...healthyBoatIds}) {
      _lostBoatContexts.remove(targetId);
    }

    final previousBoatAlerts = (_lastState?.activeAlerts ?? const [])
        .map((alert) => alert.candidate)
        .where((candidate) => candidate.category == 'other_boat');
    for (final candidate in previousBoatAlerts) {
      final targetId = candidate.targetId;
      if (targetId == null ||
          currentBoatTargetIds.contains(targetId) ||
          !effectiveUnknownBoatIds.contains(targetId)) {
        continue;
      }
      _lostBoatContexts.putIfAbsent(
        targetId,
        () => _LostBoatContext.fromLastCandidate(candidate, evaluatedAt),
      );
    }

    final retireAlertIds = <String>{};
    final expiredLostTargets = <String>[];
    for (final entry in _lostBoatContexts.entries) {
      final context = entry.value;
      if (!evaluatedAt.isBefore(context.holdUntil)) {
        retireAlertIds.add(context.physicalAlertId);
      }
      if (evaluatedAt.isAfter(context.displayUntil)) {
        expiredLostTargets.add(entry.key);
        continue;
      }
      final lostCandidate = AlertCandidate.stable(
        detectorId: 'other_boat_track_health',
        category: 'other_boat_track_lost',
        targetId: context.targetId,
        targetSessionId: context.targetSessionId,
        behavior: AlertBehavior.persistentSystemFault,
        evaluatedAt: evaluatedAt,
        observationId: observationId,
        actionDeadline: Duration.zero,
        dataQuality: AlertDataQuality.unusable,
        reasonCodes: const ['REMOTE_TRACK_LOST'],
        // 表示のみ。見失った他艇を読み上げても漕ぎながら対処できず、
        // 本当に鳴るべき衝突警告を覆い隠す(原則4)。
        // 表示は `displayUntil` まで従来どおり残す(原則1・原則6)。
        audioAsset: null,
      );
      byId[lostCandidate.alertId] = lostCandidate;
    }
    for (final targetId in expiredLostTargets) {
      _lostBoatContexts.remove(targetId);
    }
    for (final candidate in systemCandidates) {
      final existing = byId[candidate.alertId];
      if (existing == null || _prefer(candidate, existing)) {
        byId[candidate.alertId] = candidate;
      }
    }
    _applySystemFaultCuePolicy(byId, evaluatedAt: evaluatedAt);

    final previousById = {
      for (final alert in _lastState?.alerts ?? const <AlertStateView>[])
        alert.candidate.alertId: alert.candidate,
    };
    final clearEvidence = previousById.entries
        .where((entry) =>
            !byId.containsKey(entry.key) && !retireAlertIds.contains(entry.key))
        .map((entry) {
      final targetId = entry.value.targetId;
      final lostContext = targetId == null ? null : _lostBoatContexts[targetId];
      final targetIsUnknown = entry.value.category == 'other_boat' &&
          targetId != null &&
          (effectiveUnknownBoatIds.contains(targetId) ||
              (lostContext != null &&
                  evaluatedAt.isBefore(lostContext.holdUntil)));
      final isSystemFault =
          entry.value.behavior == AlertBehavior.persistentSystemFault;
      final clearQuality = isSystemFault
          ? dataQuality
          : targetIsUnknown
              ? AlertDataQuality.unusable
              : _combinedQuality(
                  dataQuality,
                  targetId == null ? null : boatDataQualityById[targetId],
                );
      return AlertClearEvidence(
        alertId: entry.key,
        observationId: observationId,
        evaluatedAt: evaluatedAt,
        dataQuality: clearQuality,
        clearConditionsMet: isSystemFault ||
            (!targetIsUnknown && clearQuality != AlertDataQuality.unusable),
      );
    });

    final state = _stateMachine.process(AlertEvaluationBatch(
      evaluatedAt: evaluatedAt,
      candidates: byId.values,
      clearEvidence: clearEvidence,
      retireAlertIds: retireAlertIds,
    ));
    _lastState = state;
    _revision += 1;

    final active = state.activeAlerts
        .map((alert) => ActiveAlert(
              candidate: alert.candidate,
              phase: alert.phase,
              dataUnknown: alert.dataUnknown,
            ))
        .toList(growable: false);
    final primary = state.primaryAlert?.candidate;
    final activeCandidates = state.activeAlerts
        .map((alert) => alert.candidate)
        .toList(growable: false);
    // 音声の対象は表示primaryとは独立に選ぶ。無音の system fault が
    // 表示primaryになっても、鳴っている音を止めないため。
    final audioTarget = _stateMachine.comparator.selectAudioPrimary(
      activeCandidates.where(_canHoldAudioChannel),
      currentAudioAlertId: _audioAlertId,
    );
    _audioAlertId = audioTarget?.alertId;
    final audio = audioTarget == null
        ? null
        : AudioDirective(
            alertId: audioTarget.alertId,
            asset: audioTarget.audioAsset!,
            mode: switch (audioTarget.behavior) {
              AlertBehavior.continuousAction => AudioDirectiveMode.loop,
              AlertBehavior.singleAction => AudioDirectiveMode.playOnce,
              AlertBehavior.entryEvent => AudioDirectiveMode.playOnce,
              AlertBehavior.visualOnly => AudioDirectiveMode.playOnce,
              AlertBehavior.persistentSystemFault => throw StateError(
                  'system fault must not enter the audio channel',
                ),
            },
            eventId: audioTarget.audioEventId,
          );
    final cues = _collectOneShotCues(
      activeCandidates,
      audioTargetAlertId: audioTarget?.alertId,
      evaluatedAt: evaluatedAt,
    );
    final full = capabilities.gpsUsable &&
        capabilities.staticProfileUsable &&
        capabilities.audioUsable &&
        capabilities.dynamicReceiveUsable &&
        capabilities.positionSharingUsable &&
        capabilities.pipelineResponsive;
    final unavailable = !capabilities.gpsUsable ||
        !capabilities.staticProfileUsable ||
        !capabilities.audioUsable ||
        !capabilities.pipelineResponsive;
    final snapshot = SafetySnapshot(
      sessionId: sessionId,
      sessionGeneration: sessionGeneration,
      revision: _revision,
      evaluatedAt: evaluatedAt,
      runMode: unavailable
          ? SafetyRunMode.unavailable
          : full
              ? SafetyRunMode.runningFull
              : SafetyRunMode.runningDegraded,
      capabilities: capabilities,
      activeAlerts: active,
      health: DetectorHealthSnapshot(detectorHealth),
      primaryAlertId: primary?.alertId,
      audioDirective: audio,
      oneShotAudioCues: cues,
      visualDirective: VisualDirective(
        active.map((alert) => alert.candidate.alertId),
      ),
    );
    return SafetyOrchestratorResult(snapshot: snapshot, state: state);
  }

  /// system faultの画面表示を残し、音声だけを必ず外す。
  ///
  /// 選手が画面を確認する運用では、GPS・通信・評価停止の読み上げが
  /// 練習の集中と物理的な衝突警告を妨げる。候補、runMode、visualDirectiveは
  /// 従来どおり維持する。
  void _applySystemFaultCuePolicy(
    Map<String, AlertCandidate> byId, {
    required DateTime evaluatedAt,
  }) {
    for (final entry in byId.entries.toList(growable: false)) {
      final candidate = entry.value;
      if (candidate.behavior != AlertBehavior.persistentSystemFault) continue;
      byId[entry.key] = candidate.copyWith(
        clearAudioAsset: true,
        clearAudioEventId: true,
        reasonCodes: [
          ...candidate.reasonCodes,
          'PRESENTATION_FAULT_VISUAL_ONLY'
        ],
      );
    }
  }

  /// 警告音チャンネルの対象になれる候補か。
  ///
  /// 音声アセットを持たない候補は最初から対象にしない。
  /// system faultはカテゴリによらずすべて画面表示だけにする。
  /// 既に単発キューで鳴らした音声イベントも対象外にして二重再生を防ぐ。
  bool _canHoldAudioChannel(AlertCandidate candidate) {
    if (candidate.behavior == AlertBehavior.persistentSystemFault) {
      return false;
    }
    if (candidate.audioAsset == null) return false;
    final eventId = candidate.audioEventId;
    return eventId == null ||
        _cuedEventIdByAlertId[candidate.alertId] != eventId;
  }

  /// 単発キューへ積む候補を集める。
  ///
  /// 持続音の対象になった候補は、そのまま [AudioDirective] で鳴るので
  /// キューへは積まない。ただし発行済みとして記録し、後で持続音の対象から
  /// 外れたときにキューで鳴り直さないようにする。
  List<AudioCue> _collectOneShotCues(
    List<AlertCandidate> activeCandidates, {
    required String? audioTargetAlertId,
    required DateTime evaluatedAt,
  }) {
    final cues = <AudioCue>[];
    for (final candidate in activeCandidates) {
      if (!_isCueEligible(candidate)) continue;
      final asset = candidate.audioAsset;
      final eventId = candidate.audioEventId;
      if (asset == null || eventId == null) continue;
      if (_handledCueEventIdByAlertId[candidate.alertId] == eventId) continue;
      _handledCueEventIdByAlertId[candidate.alertId] = eventId;
      if (candidate.alertId == audioTargetAlertId) continue;
      _cuedEventIdByAlertId[candidate.alertId] = eventId;
      cues.add(AudioCue(
        alertId: candidate.alertId,
        asset: asset,
        eventId: eventId,
        category: candidate.category,
      ));
    }
    return cues;
  }

  /// 単発キュー(2本目のプレイヤー)で鳴らす候補か。
  ///
  /// **全アセットが読み上げ音声になったので、いまは誰も該当しない。**
  ///
  /// 2本目のプレイヤーは「持続音チャンネルの取り合いに負けた候補を
  /// それでも鳴らす」ための逃げ道だった。持続音がビープ音だった頃は、
  /// その上に短い読み上げを重ねても両方聞き取れた。
  /// いまは持続音も読み上げなので、**重ねると2つの音声が同時に流れて
  /// どちらも聞き取れない**。1本を確実に伝えるほうが、2本を潰すより良い。
  ///
  /// 該当しなくなった経緯:
  ///
  /// - カーブ・逆走(`entryEvent`): 利用者が明示的に選んだ優先順位
  ///   (衝突警告 > カーブ・逆走)に従い、持続音チャンネルへ移した。
  ///   band 3 なので衝突警告に必ず負け、負けている間は無音になる。
  /// - 橋: 橋脚と同じ物理警告チャンネルで調停する。
  /// - 視覚優先 system fault(受信途絶など): 音声そのものを外した。
  ///
  /// 仕組みは残してある。読み上げと重ねても潰し合わない音
  /// (短いチャイムなど)を将来足すなら、ここが受け皿になる。
  static bool _isCueEligible(AlertCandidate candidate) => false;

  void _applyRiskPresentations(
    Map<String, AlertCandidate> byId, {
    required DateTime evaluatedAt,
    required double? ownSpeedMetersPerSecond,
    LatLng? ownPosition,
    Map<String, double?> otherBoatSpeedById = const {},
  }) {
    final riskCandidates = byId.values.toList(growable: false);
    final inMooringArea = _isInMooringArea(ownPosition);
    final guidanceIds = riskCandidates
        .where((candidate) => _isGuidance(candidate))
        .map((candidate) => candidate.alertId)
        .toSet();
    _updateGuidanceExitState(guidanceIds, evaluatedAt);

    final physicalCandidates = riskCandidates
        .where((candidate) => !_isGuidance(candidate))
        .toList(growable: false);
    final approachByAlertId = _updateMotionState(
      physicalCandidates,
      evaluatedAt: evaluatedAt,
      ownSpeedMetersPerSecond: ownSpeedMetersPerSecond,
    );
    final presentPhysicalIds =
        physicalCandidates.map((candidate) => candidate.alertId).toSet();
    for (final entry in _threatContexts.entries) {
      if (!presentPhysicalIds.contains(entry.key)) {
        final expired = entry.value.markAbsent(
          evaluatedAt,
          retentionDuration:
              presentationConfig.stableThreatEpisodeRetentionDuration,
        );
        if (expired) {
          _stableExistingThreatIds.remove(entry.key);
        }
      }
    }

    for (final candidate in riskCandidates) {
      if (_isGuidance(candidate)) {
        byId[candidate.alertId] =
            _presentGuidance(candidate, evaluatedAt: evaluatedAt);
        continue;
      }
      final context = _threatContexts.putIfAbsent(
        candidate.alertId,
        _ThreatPresentationContext.new,
      );
      final base = _basePhysicalBehavior(
        candidate,
        approaching: approachByAlertId[candidate.alertId] ?? false,
        context: context,
        evaluatedAt: evaluatedAt,
      );
      final baseBehavior = base.behavior;
      var behavior = baseBehavior;
      var repeating = base.repeating;
      final extraReasonCodes = <String>[...base.reasonCodes];
      if (_lowSpeedAudioMuted &&
          lowSpeedMutedCategories.contains(candidate.category)) {
        // 正常な橋下・岸際の休憩では、検知・表示・記録を残して音だけ止める。
        behavior = AlertBehavior.visualOnly;
        repeating = false;
      }
      if (_isUncertaintyOnlyEntry(candidate) && _isLowSpeed) {
        // 測位の不確かさでのみ重なっている候補は、自艇が低速の間は
        // 表示だけにする。停止していれば切迫していないし、疎な測位で
        // 不確かさが膨らむほど候補が現れたり消えたりして鳴り直す
        // (2026-08-05 実機ログ: 桟橋で岸の単発音が8秒周期で31回)。
        //
        // `lowSpeedMutedCategories` の3秒確定待ちと違い、ここは状態を
        // 持たない。確定待ちは有意接近のたびに巻き戻るため、
        // 測位が疎で距離がぶれる場面では効かなかった。
        behavior = AlertBehavior.visualOnly;
        repeating = false;
        extraReasonCodes.add('PRESENTATION_UNCERTAINTY_ONLY_VISUAL');
      }
      if (inMooringArea && _isLowSpeed) {
        // 桟橋エリアの中で、自艇が低速のとき。
        //
        // ここは利用者が「着艇・係留する場所」と明示的に宣言した水域である。
        // 桟橋は定義上いつも岸の隣にあり、艇は必ず岸へ寄せて止める。
        // その状況で岸・橋・橋脚の警告を鳴らすのは、原則4の
        // 「正常な運用で鳴る警告は不具合」に正面から当たる。
        //
        // - 固定危険区域(`lowSpeedMutedCategories`): 相手がいないので
        //   自艇が低速というだけで止めてよい。既存の低速静音と同じ対象だが、
        //   **3秒の確定待ちを挟まない**。確定待ちは有意接近のたびに巻き戻り、
        //   測位が疎な桟橋では成立しなかった。
        // - 他艇: **双方が低速のときだけ**。相手が動いていれば従来どおり鳴る。
        //   速度が取れない相手は抑制しない(原則6)。
        //
        // どちらも音だけを止める。表示・riskLevel・記録・位置共有は変えない。
        final silenceStatic = lowSpeedMutedCategories.contains(
          candidate.category,
        );
        final silenceBoat = candidate.category == 'other_boat' &&
            _isOtherBoatAtRest(candidate, otherBoatSpeedById);
        if (silenceStatic || silenceBoat) {
          behavior = _quieter(behavior, AlertBehavior.visualOnly);
          repeating = false;
          extraReasonCodes.add('PRESENTATION_MOORING_AREA_SILENT');
        }
      }
      final canSuppressAtRest = _canSuppressAtRest(candidate);
      // ここから下の規則はすべて**下げるだけ**である。`baseBehavior` を見て
      // 代入すると、直前に下げた結果を上書きして鳴らし直してしまう。
      // 実機ログ(2026-08-05)では、低速静音で visualOnly にした岸の警告が
      // 安定停止の分岐で singleAction へ戻り、桟橋で292サンプル鳴っていた。
      if (canSuppressAtRest &&
          _stableStopped &&
          _stableExistingThreatIds.contains(candidate.alertId) &&
          baseBehavior != AlertBehavior.visualOnly) {
        // 停止前から存在した同一脅威は表示を残しつつ音だけ止める。
        // 停止後に初めて現れた別脅威は単発音を許可する。
        behavior = _quieter(behavior, AlertBehavior.visualOnly);
        repeating = false;
      } else if (canSuppressAtRest &&
          _stableStopped &&
          baseBehavior == AlertBehavior.continuousAction) {
        behavior = _quieter(behavior, AlertBehavior.singleAction);
        repeating = false;
      } else if (canSuppressAtRest &&
          _lowSpeedActive &&
          baseBehavior == AlertBehavior.continuousAction) {
        // 休憩へ移った直後から反復音を止める。5秒の確定待ちは
        // 同一脅威を完全に無音表示へ落とすためにだけ使う。
        behavior = _quieter(behavior, AlertBehavior.singleAction);
        repeating = false;
      }
      if (canSuppressAtRest && (_stableStopped || _lowSpeedActive)) {
        // 岸際で休憩している間は断続音も止める。
        repeating = false;
      }
      final presented = context.present(
        candidate,
        behavior: behavior,
        evaluatedAt: evaluatedAt,
        repeatInterval:
            repeating ? presentationConfig.intermittentRepeatInterval : null,
        nextEventId: () => _nextAudioEventId(candidate.alertId, 'risk'),
        stableStopped: _stableStopped,
        extraReasonCodes: extraReasonCodes,
      );
      byId[candidate.alertId] = presented;
    }
  }

  Map<String, bool> _updateMotionState(
    List<AlertCandidate> candidates, {
    required DateTime evaluatedAt,
    required double? ownSpeedMetersPerSecond,
  }) {
    final approachByAlertId = <String, bool>{};
    final speed = ownSpeedMetersPerSecond;
    final usableSpeed = speed != null && speed.isFinite && speed >= 0;
    // **入るしきい値と出るしきい値を分ける(ヒステリシス)。**
    //
    // 係留中の艇は波と測位ノイズで速度が 0.0〜0.6m/s を往復する。
    // 単一のしきい値(0.4m/s)だと安定停止に入っては抜けるを繰り返し、
    // そのたびに低速静音の3秒確定待ちが巻き戻り、音声エピソードが
    // 作り直される。2026-08-05 の実機ログでは、これが桟橋での単発音の
    // 主要因のひとつだった。
    //
    // 抜けるほうだけを厳しくするので、**止まったと判定するのは今までどおり**
    // 速く、**動き出したと判定するのは慎重**になる。安全側の非対称である。
    final lowSpeedThreshold = _lowSpeedActive
        ? presentationConfig.stableStopExitSpeedMetersPerSecond
        : presentationConfig.stableStopSpeedMetersPerSecond;
    final isLowSpeed = usableSpeed && speed < lowSpeedThreshold;
    final isAudioMuteSpeed =
        usableSpeed && speed < lowSpeedAudioMuteSpeedMetersPerSecond;
    _isAudioMuteSpeedNow = isAudioMuteSpeed;
    if (!isAudioMuteSpeed) {
      final wasMuted = _lowSpeedAudioMuted;
      _lowSpeedAudioMuteStartedAt = null;
      _lowSpeedAudioMuted = false;
      if (wasMuted) {
        for (final context in _threatContexts.values) {
          context.startNewAudioEpisode();
        }
      }
    } else {
      _lowSpeedAudioMuteStartedAt ??= evaluatedAt;
      _lowSpeedAudioMuted = evaluatedAt.difference(
            _lowSpeedAudioMuteStartedAt!,
          ) >=
          lowSpeedAudioMuteConfirmation;
    }
    _lowSpeedActive = isLowSpeed;
    final wasStableStopped = _stableStopped;

    if (!isLowSpeed) {
      _lowSpeedStartedAt = null;
      _stableStopped = false;
      _stableExistingThreatIds.clear();
      for (final context in _threatContexts.values) {
        context.stopReferenceDistance = null;
      }
    } else {
      _lowSpeedStartedAt ??= evaluatedAt;
    }

    var significantApproach = false;
    for (final candidate in candidates) {
      final context = _threatContexts.putIfAbsent(
        candidate.alertId,
        _ThreatPresentationContext.new,
      );
      final previousDistance = context.lastDistanceMeters;
      final currentDistance = candidate.distanceMeters;
      final observedApproach = previousDistance != null &&
          currentDistance != null &&
          previousDistance - currentDistance >=
              presentationConfig.approachingObservationMeters;
      approachByAlertId[candidate.alertId] =
          (!isLowSpeed && usableSpeed) || observedApproach;

      if (isLowSpeed &&
          _canSuppressAtRest(candidate) &&
          // 不確かさでのみ重なっている候補の距離は、測位が疎になるほど
          // ぶれる。これを「有意接近」に数えると安定停止が繰り返し解除され、
          // 低速静音の3秒確定待ちが永久に成立しない。
          !_isUncertaintyOnlyEntry(candidate) &&
          currentDistance != null) {
        final reference = context.stopReferenceDistance;
        if (reference == null || currentDistance > reference) {
          context.stopReferenceDistance = currentDistance;
        } else if (reference - currentDistance >=
            presentationConfig.stableStopRealertApproachMeters) {
          significantApproach = true;
        }
      }
      context.recordDistance(
        currentDistance,
        at: evaluatedAt,
        window: presentationConfig.closingRateWindow,
      );
    }

    if (isLowSpeed && significantApproach) {
      // 2m以上の接近は「休憩継続」ではなく新しい危険変化として扱う。
      _lowSpeedStartedAt = evaluatedAt;
      _stableStopped = false;
      _stableExistingThreatIds.clear();
      for (final candidate in candidates) {
        final context = _threatContexts[candidate.alertId];
        context
          ?..stopReferenceDistance = candidate.distanceMeters
          ..startNewAudioEpisode();
      }
    } else if (isLowSpeed) {
      final startedAt = _lowSpeedStartedAt;
      _stableStopped = startedAt != null &&
          evaluatedAt.difference(startedAt) >=
              presentationConfig.stableStopConfirmationDuration;
    }

    if (!wasStableStopped && _stableStopped) {
      _stableExistingThreatIds
        ..clear()
        ..addAll(candidates
            .where(_canSuppressAtRest)
            .map((candidate) => candidate.alertId));
    } else if (wasStableStopped && !_stableStopped) {
      // 再航行または有意な接近で安定停止を抜けた瞬間は、新しい危険変化として
      // 一度警告できるようにする。低速が続く場合は、ここから改めて静音を判定する。
      _lowSpeedAudioMuteStartedAt = isAudioMuteSpeed ? evaluatedAt : null;
      _lowSpeedAudioMuted = false;
      for (final context in _threatContexts.values) {
        context.startNewAudioEpisode();
      }
    }
    return approachByAlertId;
  }

  void _updateGuidanceExitState(
    Set<String> presentGuidanceIds,
    DateTime evaluatedAt,
  ) {
    for (final entry in _guidanceContexts.entries) {
      if (presentGuidanceIds.contains(entry.key)) continue;
      entry.value.markOutside(evaluatedAt);
      // `reverse` 区域を出たら次の進入で改めて6秒連続を要求する。ここで
      // rearm(60秒)と混ぜない。rearm は鳴り直し間隔、こちらは逆走条件の
      // 継続確認である。
      _reverseGuidanceDebouncers[entry.key]?.reset();
    }
  }

  AlertCandidate _presentGuidance(
    AlertCandidate candidate, {
    required DateTime evaluatedAt,
  }) {
    final context = _guidanceContexts.putIfAbsent(
      candidate.alertId,
      _GuidancePresentationContext.new,
    );
    // 逆走はカーブと違い、区域の境界付近を行き来しても鳴り直さないよう
    // 長い再武装間隔を使う。実機ログでは77分で16回出入りしていた。
    final entry = context.enter(
      evaluatedAt,
      rearmDuration: candidate.category == StaticObstacleKind.reverse.name
          ? presentationConfig.reverseGuidanceRearmDuration
          : presentationConfig.guidanceRearmDuration,
      repeatInterval: presentationConfig.guidanceRepeatInterval,
      repeatMaxCount: presentationConfig.guidanceRepeatMaxCount,
      nextEventId: () => _nextAudioEventId(candidate.alertId, 'entry'),
    );
    final isConfirmedReverse =
        candidate.category == StaticObstacleKind.reverse.name &&
            candidate.reasonCodes.contains('reverse_direction_confirmed');
    final reverseConfirmed = isConfirmedReverse
        ? _reverseGuidanceDebouncers
            .putIfAbsent(candidate.alertId, ReverseGuidanceDebouncer.new)
            .update(isReverse: true, at: evaluatedAt)
        : true;
    final shouldPlay = entry.shouldPlay &&
        reverseConfirmed &&
        !(_lowSpeedAudioMuted &&
            lowSpeedMutedCategories.contains(candidate.category));
    return candidate.copyWith(
      behavior: AlertBehavior.entryEvent,
      audioAsset: shouldPlay ? candidate.audioAsset : null,
      clearAudioAsset: !shouldPlay,
      audioEventId: shouldPlay ? entry.audioEventId : null,
      clearAudioEventId: !shouldPlay,
      reasonCodes: [
        ...candidate.reasonCodes,
        if (!reverseConfirmed)
          'REVERSE_CONFIRM_PENDING'
        else if (!entry.shouldPlay)
          'GUIDANCE_REARM_PENDING'
        else if (entry.repeatIndex == 0)
          'GUIDANCE_ENTRY'
        else
          'GUIDANCE_REPEAT',
      ],
    );
  }

  /// 音の鳴り方を「到達までの時間」だけで決める。
  ///
  /// 内部レベル(lv0〜3)は表示色・優先順位・ログ専用にし、ここでは見ない。
  /// 到達予測が無い候補(近接注意・DCPA近接)だけ別扱いにする。
  _PhysicalPresentation _basePhysicalBehavior(
    AlertCandidate candidate, {
    required bool approaching,
    required _ThreatPresentationContext context,
    required DateTime evaluatedAt,
  }) {
    final deadline = candidate.actionDeadline;
    if (deadline == null && !candidate.currentOverlap) {
      return _proximityPresentation(
        candidate,
        approaching: approaching,
        context: context,
      );
    }

    final steadyOverlap = candidate.currentOverlap
        ? _overlapUrgency(candidate, context: context, evaluatedAt: evaluatedAt)
        : null;
    var urgency = candidate.currentOverlap
        ? steadyOverlap!.urgency
        : deadline == null
            ? AlertUrgency.monitoring
            : deadline <= presentationConfig.continuousAudioDeadline
                ? AlertUrgency.imminent
                : deadline <= presentationConfig.intermittentAudioDeadline
                    ? AlertUrgency.approaching
                    : AlertUrgency.monitoring;

    // GPS帯込みでのみ重なる「不確実」な候補は1段下げる。
    // 連続音が本当に切迫しているときだけ鳴るようにする。
    if (candidate.confidence < 1.0) urgency = urgency.oneStepDown;

    final reasonCodes = steadyOverlap?.reasonCodes ?? const <String>[];

    // 橋のように毎回通過する区域は連続音まで上げない。
    if (urgency == AlertUrgency.imminent &&
        bandCappedCategories.contains(candidate.category)) {
      return _PhysicalPresentation(
        behavior: AlertBehavior.singleAction,
        repeating: false,
        reasonCodes: reasonCodes,
      );
    }

    return switch (urgency) {
      AlertUrgency.imminent => _PhysicalPresentation(
          behavior: AlertBehavior.continuousAction,
          repeating: false,
          reasonCodes: reasonCodes,
        ),
      // 断続音: 同じ脅威が続く間、一定間隔で鳴らし直す。
      AlertUrgency.approaching => _PhysicalPresentation(
          behavior: AlertBehavior.singleAction,
          repeating: true,
          reasonCodes: reasonCodes,
        ),
      AlertUrgency.monitoring => _PhysicalPresentation(
          behavior: AlertBehavior.visualOnly,
          repeating: false,
          reasonCodes: reasonCodes,
        ),
    };
  }

  /// 「重なっている」を切迫度へ翻訳する。
  ///
  /// `currentOverlap` は「どれだけまずいか」であって「どれだけ切迫して
  /// いるか」ではない(原則5)。岸との並走・桟橋への係留は重なっているが
  /// 距離は縮まっていない。既存の停止時抑制は**自艇が止まっているとき**
  /// しか働かないので、「**距離が縮まっていないとき**」へ一般化する。
  ///
  /// - 距離が [AlertPresentationConfig.staticOverlapClosingRateMetersPerSecond]
  ///   以上で縮まっている → 従来どおり連続音
  /// - 距離が取得できない → 接近中として扱い連続音(原則6)
  /// - 縮まっていない → 断続音へ1段下げ、猶予を過ぎたら表示のみ
  /// - 再び [AlertPresentationConfig.stableStopRealertApproachMeters] 縮まったら再武装
  ///
  /// 他艇は相手が接近してくるため対象外([_canSuppressAtRest])。
  _SteadyOverlapDecision _overlapUrgency(
    AlertCandidate candidate, {
    required _ThreatPresentationContext context,
    required DateTime evaluatedAt,
  }) {
    if (!_canSuppressAtRest(candidate)) {
      context.resetSteadyOverlap();
      return const _SteadyOverlapDecision(AlertUrgency.imminent);
    }
    final closingRate = context.closingRateMetersPerSecond(evaluatedAt);
    final closing = closingRate == null ||
        closingRate >=
            presentationConfig.staticOverlapClosingRateMetersPerSecond;
    if (closing) {
      context.resetSteadyOverlap();
      return const _SteadyOverlapDecision(AlertUrgency.imminent);
    }
    if (context.observeSteadyOverlapRearm(
      distanceMeters: candidate.distanceMeters,
      rearmApproachMeters: presentationConfig.stableStopRealertApproachMeters,
    )) {
      return const _SteadyOverlapDecision(AlertUrgency.imminent);
    }
    final steadySince = context.markSteadyOverlap(evaluatedAt);
    if (evaluatedAt.difference(steadySince) >=
        presentationConfig.staticOverlapImminentGrace) {
      return const _SteadyOverlapDecision(
        AlertUrgency.monitoring,
        ['PRESENTATION_STEADY_OVERLAP_SILENT'],
      );
    }
    return const _SteadyOverlapDecision(
      AlertUrgency.approaching,
      ['PRESENTATION_STEADY_OVERLAP_INTERMITTENT'],
    );
  }

  /// 到達予測が無い候補(近接注意・DCPA近接)の提示を決める。
  _PhysicalPresentation _proximityPresentation(
    AlertCandidate candidate, {
    required bool approaching,
    required _ThreatPresentationContext context,
  }) {
    const visual = _PhysicalPresentation(
      behavior: AlertBehavior.visualOnly,
      repeating: false,
    );
    if (!audibleProximityCategories.contains(candidate.category)) {
      return visual;
    }
    // 接近している間は singleAction を返し続ける。同一エピソード中は
    // audioEventId が保たれるため、実際に鳴るのは1回だけになる。
    // 十分離れたら新しいエピソードにして、再接近時に鳴り直せるようにする。
    context.updateProximityEpisode(
      distanceMeters: candidate.distanceMeters,
      rearmMeters: presentationConfig.proximityAudioRearmMeters,
    );
    return approaching
        ? const _PhysicalPresentation(
            behavior: AlertBehavior.singleAction,
            repeating: false,
          )
        : visual;
  }

  String _nextAudioEventId(String alertId, String kind) {
    _audioEventSequence += 1;
    return '$sessionId:$kind:$_audioEventSequence:$alertId';
  }

  static bool _isGuidance(AlertCandidate candidate) =>
      candidate.detectorId == 'guidance_zone_entry';

  /// 提示の重さ。音の大きさではなく「どれだけ鳴らすか」の順序。
  static int _behaviorLoudness(AlertBehavior behavior) => switch (behavior) {
        AlertBehavior.continuousAction => 3,
        AlertBehavior.singleAction => 2,
        AlertBehavior.entryEvent => 1,
        AlertBehavior.visualOnly => 0,
        AlertBehavior.persistentSystemFault => 0,
      };

  /// 静かなほうを返す。抑制規則は下げるだけで、上げてはいけない。
  static AlertBehavior _quieter(AlertBehavior a, AlertBehavior b) =>
      _behaviorLoudness(a) <= _behaviorLoudness(b) ? a : b;

  /// 実体ではなく測位の不確かさでのみ重なっている候補か。
  ///
  /// `gps_guard_entry` は「GPS帯を含めたときだけ重なる」という意味で、
  /// `continuous_domain_entry`(実体の掃引が重なった)と同時には立たない。
  /// 測位が疎になるほど不確かさが膨らんで現れやすくなるため、
  /// これだけを根拠に音を鳴らすと、測位品質の低下が過剰警告に化ける。
  static bool _isUncertaintyOnlyEntry(AlertCandidate candidate) =>
      candidate.reasonCodes.contains('gps_guard_entry');

  /// 自艇が「休憩とみなせる低速」か。**状態を持たない即値判定**。
  ///
  /// `_lowSpeedAudioMuted` は3秒の確定待ちを持ち、有意接近のたびに
  /// 巻き戻る。測位が疎で距離がぶれる場面ではその巻き戻りが連続し、
  /// 静音が成立しなかった。ここは確定待ちを持たない生の速度で判定する。
  bool get _isLowSpeed => _isAudioMuteSpeedNow;

  /// 桟橋エリアの中にいるか。座標が無ければ**外**として扱う(抑制しない)。
  bool _isInMooringArea(LatLng? position) {
    if (position == null || mooringAreas.isEmpty) return false;
    for (final polygon in mooringAreas) {
      if (polygon.length < 3) continue;
      if (isPointInPolygon(position, polygon)) return true;
    }
    return false;
  }

  /// 相手も止まっているか。
  ///
  /// **速度が取れないときは false を返す**(原則6: データ欠損は静音の
  /// 根拠にならない)。桟橋でも、動いている艇・速度不明の艇には鳴らす。
  bool _isOtherBoatAtRest(
    AlertCandidate candidate,
    Map<String, double?> otherBoatSpeedById,
  ) {
    final targetId = candidate.targetId;
    if (targetId == null) return false;
    final speed = otherBoatSpeedById[targetId];
    if (speed == null || !speed.isFinite || speed < 0) return false;
    return speed < presentationConfig.stableStopSpeedMetersPerSecond;
  }

  /// 岸・橋など固定物のそばで休憩するときだけ反復音を抑える。
  ///
  /// 自艇が停止していても他艇側が接近する可能性は残るため、他艇の
  /// 緊急警告は安定停止による無音化の対象にしない。
  static bool _canSuppressAtRest(AlertCandidate candidate) =>
      candidate.category != 'other_boat';

  AlertCandidate _fromRiskThreat(
    RiskThreat riskThreat, {
    required DateTime evaluatedAt,
    required String observationId,
    required AlertDataQuality dataQuality,
  }) {
    final threat = riskThreat.threat;
    if (threat.kind == ThreatKind.boat) {
      return AlertCandidate.stable(
        detectorId: 'relative_boat_collision',
        category: 'other_boat',
        targetId: threat.boatId ?? 'unknown',
        targetSessionId: threat.boatSessionId,
        behavior: AlertBehavior.continuousAction,
        evaluatedAt: evaluatedAt,
        observationId: observationId,
        internalPriority: riskThreat.level.index,
        actionDeadline: _deadline(threat),
        currentOverlap: threat.continuousIntersection?.currentOverlap ?? false,
        confidence: threat.confidence == ThreatConfidence.definite ? 1.0 : 0.7,
        dataQuality: dataQuality,
        distanceMeters: threat.distanceMeters ??
            threat.continuousIntersection?.firstEntryDistanceMeters,
        relativeBearingDegrees: threat.relativeBearingDegrees,
        separationMeters: threat.separationMeters,
        reasonCodes: threat.continuousIntersection?.reasonCodes ?? const [],
        audioAsset: otherBoatWarningAudioAsset,
      );
    }

    final kind = threat.obstacleKind ?? StaticObstacleKind.generic;
    // 基準線は辺ごとの長方形へ展開されるため、`obstacleId` をそのまま
    // targetId にすると `shore_north_65 → _66 → _67` が別々の警告になり、
    // 岸沿いで音声エピソードが連鎖する。橋も手前の面と奥の面で二重に鳴る。
    // 人が認識する単位(= 生成元の基準線)へ集約し、代表の辺は
    // `_prefer` が「最も切迫した辺」として選ぶ。
    final sourceId = threat.obstacleSourceId;
    // 同じ橋の左右の橋脚は、最も切迫した1本を代表にして1警告へまとめる。
    final aggregatedTargetId = kind == StaticObstacleKind.bridgePier
        ? (threat.obstacleBridgeId ??
            sourceId ??
            threat.obstacleId ??
            kind.name)
        : (sourceId ?? threat.obstacleId ?? kind.name);
    // 集約すると診断ログから元の辺が追えなくなるため、代表になった辺を残す。
    final sourceEdgeReason = sourceId != null && threat.obstacleId != null
        ? ['SOURCE_EDGE:${threat.obstacleId}']
        : const <String>[];
    // カーブ・逆走注意は物理障害物と分離し、区域進入イベントとして
    // 提示する。退出後の再通知待ちはpresentation contextで管理する。
    return AlertCandidate.stable(
      detectorId:
          kind.isEntryGuidance ? 'guidance_zone_entry' : 'static_collision',
      category: kind.name,
      targetId: aggregatedTargetId,
      behavior: kind.isEntryGuidance
          ? AlertBehavior.entryEvent
          : AlertBehavior.continuousAction,
      evaluatedAt: evaluatedAt,
      observationId: observationId,
      internalPriority: riskThreat.level.index,
      actionDeadline: _deadline(threat),
      currentOverlap:
          threat.continuousIntersection?.currentOverlap ?? kind.isEntryGuidance,
      confidence: threat.confidence == ThreatConfidence.definite ? 1.0 : 0.7,
      dataQuality: dataQuality,
      distanceMeters: threat.distanceMeters ??
          threat.continuousIntersection?.firstEntryDistanceMeters,
      relativeBearingDegrees: threat.relativeBearingDegrees,
      separationMeters: threat.separationMeters,
      reasonCodes: [
        ...?threat.continuousIntersection?.reasonCodes,
        ...sourceEdgeReason,
      ],
      audioAsset: threat.warningAudioAsset ?? defaultWarningAudioAssetFor(kind),
    );
  }

  static Duration? _deadline(ThreatInfo threat) {
    final seconds = threat.continuousIntersection?.firstEntryTimeSeconds;
    if (seconds == null || !seconds.isFinite) return null;
    return Duration(milliseconds: (seconds.clamp(0, 3600) * 1000).round());
  }

  static bool _prefer(AlertCandidate next, AlertCandidate current) {
    if (next.currentOverlap != current.currentOverlap) {
      return next.currentOverlap;
    }
    final nextDeadline = next.actionDeadline ?? const Duration(days: 3650);
    final currentDeadline =
        current.actionDeadline ?? const Duration(days: 3650);
    if (nextDeadline != currentDeadline) return nextDeadline < currentDeadline;
    if (next.internalPriority != current.internalPriority) {
      return next.internalPriority > current.internalPriority;
    }
    // sourceId 集約で同じalertIdになった辺のうち、最も近い辺を代表にする。
    // 入力順に依存すると代表が毎秒入れ替わり、接近速度の履歴が乱れる。
    return _distanceRank(next) < _distanceRank(current);
  }

  static double _distanceRank(AlertCandidate candidate) {
    final distance = candidate.distanceMeters;
    if (distance == null || !distance.isFinite) return double.infinity;
    return distance;
  }

  static AlertDataQuality _combinedQuality(
    AlertDataQuality ownQuality,
    AlertDataQuality? targetQuality,
  ) {
    if (targetQuality == null) return ownQuality;
    return ownQuality.index >= targetQuality.index ? ownQuality : targetQuality;
  }
}

/// 提示の決定結果。断続音かどうかは behavior だけでは表せないため分ける。
class _PhysicalPresentation {
  final AlertBehavior behavior;
  final bool repeating;

  /// 診断ログ用に候補へ足す理由コード。
  final List<String> reasonCodes;

  const _PhysicalPresentation({
    required this.behavior,
    required this.repeating,
    this.reasonCodes = const [],
  });
}

/// 重なったまま接近していない状態の判定結果。
class _SteadyOverlapDecision {
  final AlertUrgency urgency;
  final List<String> reasonCodes;

  const _SteadyOverlapDecision(this.urgency, [this.reasonCodes = const []]);
}

class _LostBoatContext {
  final String targetId;
  final String? targetSessionId;
  final String physicalAlertId;
  final DateTime holdUntil;
  final DateTime displayUntil;

  const _LostBoatContext({
    required this.targetId,
    required this.targetSessionId,
    required this.physicalAlertId,
    required this.holdUntil,
    required this.displayUntil,
  });

  factory _LostBoatContext.fromLastCandidate(
    AlertCandidate candidate,
    DateTime lostAt,
  ) {
    final deadlineSeconds = candidate.actionDeadline == null
        ? 2.0
        : candidate.actionDeadline!.inMilliseconds / 1000;
    final holdSeconds = (deadlineSeconds + 3).clamp(5.0, 12.0);
    final holdUntil = lostAt.add(
      Duration(milliseconds: (holdSeconds * 1000).round()),
    );
    return _LostBoatContext(
      targetId: candidate.targetId!,
      targetSessionId: candidate.targetSessionId,
      physicalAlertId: candidate.alertId,
      holdUntil: holdUntil,
      displayUntil: holdUntil.add(const Duration(seconds: 30)),
    );
  }
}

/// 接近速度を求めるための距離標本。
class _DistanceSample {
  final DateTime at;
  final double distanceMeters;

  const _DistanceSample(this.at, this.distanceMeters);
}

class _ThreatPresentationContext {
  /// 距離の短い履歴。接近速度も直前距離もここから読む。
  final List<_DistanceSample> _distanceSamples = [];
  double? stopReferenceDistance;
  bool _wasPresent = false;
  String? _audioEventId;
  DateTime? _absentSince;
  DateTime? _lastAudibleAt;
  double? _proximityClosestDistance;
  DateTime? _steadyOverlapSince;
  double? _steadyOverlapReferenceDistance;

  /// 直前の観測距離。履歴の末尾と同じものを指す。
  double? get lastDistanceMeters =>
      _distanceSamples.isEmpty ? null : _distanceSamples.last.distanceMeters;

  /// 距離を記録し、観測窓より古い標本を捨てる。
  ///
  /// 距離が取れなかったティックでは履歴を捨てる。欠損をまたいで
  /// 差分を取ると、実際には縮まっていない区間を「縮まった」と読む。
  void recordDistance(
    double? distanceMeters, {
    required DateTime at,
    required Duration window,
  }) {
    if (distanceMeters == null || !distanceMeters.isFinite) {
      _distanceSamples.clear();
      return;
    }
    _distanceSamples.add(_DistanceSample(at, distanceMeters));
    final oldest = at.subtract(window);
    _distanceSamples.removeWhere((sample) => sample.at.isBefore(oldest));
  }

  /// 観測窓ぶんの距離差から求めた接近速度 [m/s]。正が接近。
  ///
  /// 標本が足りない、または時間差が無いときは null を返す。呼び出し側は
  /// null を「接近中」として扱う(原則6: データ欠損は安全の根拠にならない)。
  double? closingRateMetersPerSecond(DateTime at) {
    if (_distanceSamples.length < 2) return null;
    final first = _distanceSamples.first;
    final last = _distanceSamples.last;
    final seconds = last.at.difference(first.at).inMicroseconds / 1e6;
    if (seconds <= 0) return null;
    return (first.distanceMeters - last.distanceMeters) / seconds;
  }

  void resetSteadyOverlap() {
    _steadyOverlapSince = null;
    _steadyOverlapReferenceDistance = null;
  }

  /// 縮まらない重なりの基準距離を更新し、再武装すべきかを返す。
  ///
  /// 接近速度がしきい値に届かないまま、じわじわ [rearmApproachMeters] 縮んだ
  /// ときは新しい危険変化として扱う(安定停止の再警告と同じ基準)。
  bool observeSteadyOverlapRearm({
    required double? distanceMeters,
    required double rearmApproachMeters,
  }) {
    final distance = distanceMeters;
    if (distance == null) return false;
    final reference = _steadyOverlapReferenceDistance;
    if (reference == null || distance > reference) {
      _steadyOverlapReferenceDistance = distance;
      return false;
    }
    if (reference - distance < rearmApproachMeters) return false;
    _steadyOverlapSince = null;
    _steadyOverlapReferenceDistance = distance;
    return true;
  }

  /// 縮まらない重なりが始まった時刻を返す(初回は [at] を記録する)。
  DateTime markSteadyOverlap(DateTime at) => _steadyOverlapSince ??= at;

  /// 近接注意の「接近エピソード」を更新する。
  ///
  /// エピソード中の最接近距離を覚えておき、そこから [rearmMeters] 以上
  /// 離れたら新しいエピソードにする。これにより、同じ場所に留まっている
  /// 間は鳴り直さず、いったん離れて再び近づいたときだけ鳴り直す。
  void updateProximityEpisode({
    required double? distanceMeters,
    required double rearmMeters,
  }) {
    final distance = distanceMeters;
    if (distance == null) return;
    final closest = _proximityClosestDistance;
    if (closest != null && distance >= closest + rearmMeters) {
      startNewAudioEpisode();
      _proximityClosestDistance = distance;
      return;
    }
    if (closest == null || distance < closest) {
      _proximityClosestDistance = distance;
    }
  }

  AlertCandidate present(
    AlertCandidate candidate, {
    required AlertBehavior behavior,
    required DateTime evaluatedAt,
    required Duration? repeatInterval,
    required String Function() nextEventId,
    required bool stableStopped,
    List<String> extraReasonCodes = const [],
  }) {
    final isAudible = behavior == AlertBehavior.continuousAction ||
        behavior == AlertBehavior.singleAction;
    if (isAudible) {
      final lastAudibleAt = _lastAudibleAt;
      final shouldRepeat = repeatInterval != null &&
          lastAudibleAt != null &&
          evaluatedAt.difference(lastAudibleAt) >= repeatInterval;
      if (_audioEventId == null || shouldRepeat) {
        _audioEventId = nextEventId();
        _lastAudibleAt = evaluatedAt;
      }
    } else if (!stableStopped) {
      _audioEventId = null;
      _lastAudibleAt = null;
    }
    _wasPresent = true;
    _absentSince = null;

    final reasonCode = switch (behavior) {
      AlertBehavior.continuousAction => 'PRESENTATION_EMERGENCY',
      AlertBehavior.singleAction => stableStopped
          ? 'PRESENTATION_STABLE_STOP_SINGLE'
          : repeatInterval != null
              ? 'PRESENTATION_ACTION_INTERMITTENT'
              : 'PRESENTATION_ACTION_ONCE',
      AlertBehavior.visualOnly => stableStopped
          ? 'PRESENTATION_STABLE_STOP_SILENT'
          : 'PRESENTATION_CAUTION_VISUAL',
      AlertBehavior.entryEvent => 'PRESENTATION_GUIDANCE_ENTRY',
      AlertBehavior.persistentSystemFault => 'PRESENTATION_SYSTEM_FAULT',
    };
    return candidate.copyWith(
      behavior: behavior,
      audioAsset: isAudible ? candidate.audioAsset : null,
      clearAudioAsset: !isAudible,
      audioEventId: isAudible ? _audioEventId : null,
      clearAudioEventId: !isAudible,
      reasonCodes: [...candidate.reasonCodes, ...extraReasonCodes, reasonCode],
    );
  }

  bool markAbsent(
    DateTime evaluatedAt, {
    required Duration retentionDuration,
  }) {
    if (_wasPresent) {
      _absentSince = evaluatedAt;
    }
    _wasPresent = false;
    _distanceSamples.clear();
    stopReferenceDistance = null;
    resetSteadyOverlap();
    final absentSince = _absentSince;
    // **停止中かどうかに関係なく、短い不在では音声エピソードを据え置く。**
    //
    // 以前は `stableStopped` のときだけ据え置いていたため、GPSが数秒
    // 途絶えて候補が消え、復帰した瞬間に「新しい脅威」として単発音が
    // 鳴り直していた。2026-08-05 の実機ログでは、桟橋で岸の単発音が
    // GPS再接続の8秒周期に同期して31回鳴っている(24回中18回が再接続の
    // ±2秒以内)。測位の欠測は脅威が消えた証拠ではない(原則6)。
    //
    // 据え置いても連続音は止まらない。持続音は directive が消えた時点で
    // 停止し、戻れば再開する。据え置きが効くのは `playOnce` の
    // eventId 重複排除であり、「同じ脅威を鳴らし直さない」だけである。
    final expired = absentSince == null ||
        evaluatedAt.difference(absentSince) >= retentionDuration;
    if (expired) {
      _audioEventId = null;
      _lastAudibleAt = null;
      _proximityClosestDistance = null;
    }
    return expired;
  }

  void startNewAudioEpisode() {
    _audioEventId = null;
    _lastAudibleAt = null;
    _proximityClosestDistance = null;
  }
}

/// カーブ・逆走の読み上げ状態。
///
/// 区域内にいる間は [repeatInterval] ごとに新しい音声イベントIDを発行し、
/// 同じ読み上げを鳴らし直す。1回だけでは聞き逃すため(利用者判断)。
///
/// **鳴らないことは正常な結果である。** ここが返す `shouldPlay` は
/// 「鳴らしてよい」であって「鳴る」ではない。区域進入は
/// `AlertBehavior.entryEvent`(band 3)なので、衝突警告が持続音チャンネルを
/// 握っている間は選ばれない。イベントIDだけが裏で進み、衝突警告が
/// 消えた次の周期から読み上げが戻る。
class _GuidancePresentationContext {
  bool _inside = false;
  DateTime? _outsideSince;
  bool _shouldPlayForCurrentEntry = false;
  String? _audioEventId;

  /// 現在の滞在で最後にイベントIDを発行した時刻。
  DateTime? _lastAnnouncedAt;

  /// 現在の滞在での発行回数。0 が進入時の1回目。
  int _repeatIndex = 0;

  void markOutside(DateTime evaluatedAt) {
    if (!_inside) return;
    _inside = false;
    _outsideSince = evaluatedAt;
    _shouldPlayForCurrentEntry = false;
    _audioEventId = null;
    _lastAnnouncedAt = null;
    _repeatIndex = 0;
  }

  _GuidanceEntry enter(
    DateTime evaluatedAt, {
    required Duration rearmDuration,
    required Duration repeatInterval,
    required int? repeatMaxCount,
    required String Function() nextEventId,
  }) {
    if (_inside) {
      if (!_shouldPlayForCurrentEntry) {
        // 再武装待ちの滞在。この滞在では一度も鳴らさない。
        return const _GuidanceEntry(
          shouldPlay: false,
          audioEventId: null,
          repeatIndex: 0,
        );
      }
      final lastAt = _lastAnnouncedAt;
      final reachedCap =
          repeatMaxCount != null && _repeatIndex + 1 >= repeatMaxCount;
      // 時計が巻き戻った場合は基点を引き直し、即座に鳴らし直さない。
      if (lastAt != null && evaluatedAt.isBefore(lastAt)) {
        _lastAnnouncedAt = evaluatedAt;
      } else if (lastAt != null &&
          !reachedCap &&
          evaluatedAt.difference(lastAt) >= repeatInterval) {
        _lastAnnouncedAt = evaluatedAt;
        _repeatIndex += 1;
        _audioEventId = nextEventId();
      }
      return _GuidanceEntry(
        shouldPlay: true,
        audioEventId: _audioEventId,
        repeatIndex: _repeatIndex,
      );
    }

    final outsideSince = _outsideSince;
    final rearmed = outsideSince == null ||
        evaluatedAt.difference(outsideSince) >= rearmDuration;
    _inside = true;
    _outsideSince = null;
    _shouldPlayForCurrentEntry = rearmed;
    _audioEventId = rearmed ? nextEventId() : null;
    _lastAnnouncedAt = rearmed ? evaluatedAt : null;
    _repeatIndex = 0;
    return _GuidanceEntry(
      shouldPlay: _shouldPlayForCurrentEntry,
      audioEventId: _audioEventId,
      repeatIndex: 0,
    );
  }
}

class _GuidanceEntry {
  final bool shouldPlay;
  final String? audioEventId;

  /// 現在の滞在での発行回数。0 が進入時の1回目。
  final int repeatIndex;

  const _GuidanceEntry({
    required this.shouldPlay,
    required this.audioEventId,
    required this.repeatIndex,
  });
}
