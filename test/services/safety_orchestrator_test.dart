import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/config/alert_presentation_config.dart';
import 'package:rowing_navigator/models/alert_candidate.dart';
import 'package:rowing_navigator/models/safety_snapshot.dart';
import 'package:rowing_navigator/models/static_obstacle_model.dart';
import 'package:rowing_navigator/services/collision_risk_evaluator_service.dart';
import 'package:rowing_navigator/services/continuous_collision_service.dart';
import 'package:rowing_navigator/services/safety_orchestrator.dart';
import 'package:rowing_navigator/types/collision_risk_level.dart';

void main() {
  final t0 = DateTime.utc(2026, 7, 15, 12);
  const capabilities = CapabilitySnapshot(
    gpsUsable: true,
    staticProfileUsable: true,
    audioUsable: true,
  );

  RiskThreat boatThreat(
    String id, {
    double entrySeconds = 5,
    CollisionRiskLevel level = CollisionRiskLevel.lv2,
  }) =>
      RiskThreat(
        level: level,
        threat: ThreatInfo(
          kind: ThreatKind.boat,
          position: const LatLng(36.0, 140.0),
          boatId: id,
          continuousIntersection: ContinuousIntersection(
            intersects: true,
            currentOverlap: false,
            firstEntryTimeSeconds: entrySeconds,
            firstExitTimeSeconds: entrySeconds + 2,
            firstEntryDistanceMeters: entrySeconds * 4,
            minimumSeparationMeters: 0,
          ),
        ),
      );

  RiskThreat staticThreat(
    String id, {
    CollisionRiskLevel level = CollisionRiskLevel.lv2,
    double entrySeconds = 5,
    double distanceMeters = 20,
    bool overlap = false,
    StaticObstacleKind kind = StaticObstacleKind.shore,
    ThreatConfidence confidence = ThreatConfidence.definite,
  }) =>
      RiskThreat(
        level: level,
        threat: ThreatInfo(
          kind: ThreatKind.obstacle,
          position: const LatLng(36.0, 140.0),
          obstacleKind: kind,
          obstacleId: id,
          confidence: confidence,
          distanceMeters: distanceMeters,
          continuousIntersection: ContinuousIntersection(
            intersects: true,
            currentOverlap: overlap,
            firstEntryTimeSeconds: overlap ? 0 : entrySeconds,
            firstExitTimeSeconds: entrySeconds + 2,
            firstEntryDistanceMeters: overlap ? 0 : entrySeconds * 4,
            minimumSeparationMeters: 0,
          ),
        ),
      );

  RiskAssessment assessment(Iterable<RiskThreat> threats) => RiskAssessment(
        level:
            threats.isEmpty ? CollisionRiskLevel.lv0 : CollisionRiskLevel.lv2,
        primaryThreat: threats.isEmpty ? null : threats.first.threat,
        threats: threats,
      );

  test('他艇の警告は2観測と1秒でactiveになり、到達5秒なら連続音で鳴る', () {
    final orchestrator = SafetyOrchestrator(
      sessionId: 'session-a',
      sessionGeneration: 1,
    );
    final risks = assessment([
      boatThreat('boat-b', entrySeconds: 8),
      boatThreat('boat-a', entrySeconds: 5),
    ]);

    final first = orchestrator.processAssessment(
      assessment: risks,
      evaluatedAt: t0,
      capabilities: capabilities,
    );
    expect(first.snapshot.activeAlerts, isEmpty);

    final second = orchestrator.processAssessment(
      assessment: risks,
      evaluatedAt: t0.add(const Duration(seconds: 1)),
      capabilities: capabilities,
    );
    expect(second.snapshot.activeAlerts, hasLength(2));
    expect(second.state.primaryAlert!.candidate.targetId, 'boat-a');
    // 到達5秒は連続音バンド(7秒以内)。漕手は後ろ向きなので、
    // 単発1回では聞き逃す前提で設計している。
    expect(second.snapshot.audioDirective!.mode, AudioDirectiveMode.loop);
    expect(second.snapshot.audioDirective!.eventId, isNotNull);
  });

  test('通常品質は単発safeで音を止めず2秒で解除する', () {
    final orchestrator = SafetyOrchestrator(
      sessionId: 'session-a',
      sessionGeneration: 1,
    );
    final danger = assessment([boatThreat('boat-a')]);
    final safe = assessment(const []);
    orchestrator.processAssessment(
      assessment: danger,
      evaluatedAt: t0,
      capabilities: capabilities,
    );
    orchestrator.processAssessment(
      assessment: danger,
      evaluatedAt: t0.add(const Duration(seconds: 1)),
      capabilities: capabilities,
    );

    final clearing = orchestrator.processAssessment(
      assessment: safe,
      evaluatedAt: t0.add(const Duration(seconds: 2)),
      capabilities: capabilities,
      healthyBoatIds: const {'boat-a'},
    );
    expect(clearing.snapshot.activeAlerts, hasLength(1));
    expect(clearing.snapshot.audioDirective, isNotNull);

    final oneSecond = orchestrator.processAssessment(
      assessment: safe,
      evaluatedAt: t0.add(const Duration(seconds: 3)),
      capabilities: capabilities,
      healthyBoatIds: const {'boat-a'},
    );
    expect(oneSecond.snapshot.activeAlerts, hasLength(1));

    final cleared = orchestrator.processAssessment(
      assessment: safe,
      evaluatedAt: t0.add(const Duration(seconds: 4)),
      capabilities: capabilities,
      healthyBoatIds: const {'boat-a'},
    );
    expect(cleared.snapshot.activeAlerts, isEmpty);
    expect(cleared.snapshot.audioDirective, isNull);
  });

  test('他艇データがdegradedなら解除を3秒へ延長する', () {
    final orchestrator = SafetyOrchestrator(
      sessionId: 'session-a',
      sessionGeneration: 1,
    );
    final danger = assessment([boatThreat('boat-a')]);
    final safe = assessment(const []);
    orchestrator.processAssessment(
      assessment: danger,
      evaluatedAt: t0,
      capabilities: capabilities,
      boatDataQualityById: const {
        'boat-a': AlertDataQuality.degraded,
      },
    );
    orchestrator.processAssessment(
      assessment: danger,
      evaluatedAt: t0.add(const Duration(seconds: 1)),
      capabilities: capabilities,
      boatDataQualityById: const {
        'boat-a': AlertDataQuality.degraded,
      },
    );

    orchestrator.processAssessment(
      assessment: safe,
      evaluatedAt: t0.add(const Duration(seconds: 2)),
      capabilities: capabilities,
      healthyBoatIds: const {'boat-a'},
      boatDataQualityById: const {
        'boat-a': AlertDataQuality.degraded,
      },
    );
    final twoObservations = orchestrator.processAssessment(
      assessment: safe,
      evaluatedAt: t0.add(const Duration(seconds: 3)),
      capabilities: capabilities,
      healthyBoatIds: const {'boat-a'},
      boatDataQualityById: const {
        'boat-a': AlertDataQuality.degraded,
      },
    );
    expect(twoObservations.snapshot.activeAlerts, hasLength(1));

    final twoSeconds = orchestrator.processAssessment(
      assessment: safe,
      evaluatedAt: t0.add(const Duration(seconds: 4)),
      capabilities: capabilities,
      healthyBoatIds: const {'boat-a'},
      boatDataQualityById: const {
        'boat-a': AlertDataQuality.degraded,
      },
    );
    expect(twoSeconds.snapshot.activeAlerts, hasLength(1));

    final cleared = orchestrator.processAssessment(
      assessment: safe,
      evaluatedAt: t0.add(const Duration(seconds: 5)),
      capabilities: capabilities,
      healthyBoatIds: const {'boat-a'},
      boatDataQualityById: const {
        'boat-a': AlertDataQuality.degraded,
      },
    );
    expect(cleared.snapshot.activeAlerts, isEmpty);
  });

  test('無音のGPS異常でも表示は即座に立つ(不変条件3)', () {
    // system faultは常に画面表示だけだが、候補まで消してはいけない。
    // `AlertDataQuality.unusable` で物理警告が3秒後に終わったとき、
    // 理由が表示されない窓を作らないためである。
    final orchestrator = SafetyOrchestrator(
      sessionId: 'session-gps-silent',
      sessionGeneration: 1,
    );
    const degraded = CapabilitySnapshot(
      gpsUsable: false,
      staticProfileUsable: true,
      audioUsable: true,
    );
    final silentFault = AlertCandidate.stable(
      detectorId: 'gps_health',
      category: 'gps_unavailable',
      behavior: AlertBehavior.persistentSystemFault,
      evaluatedAt: t0,
      observationId: 'gps-silent-0',
      actionDeadline: Duration.zero,
      audioAsset: null,
    );

    final result = orchestrator.processAssessment(
      assessment: assessment(const []),
      evaluatedAt: t0,
      capabilities: degraded,
      dataQuality: AlertDataQuality.unusable,
      systemCandidates: [silentFault],
    );

    // 表示は出る。runMode と理由の表示が食い違わない。
    expect(
      result.snapshot.activeAlerts
          .any((alert) => alert.candidate.category == 'gps_unavailable'),
      isTrue,
      reason: '音声が無くても候補は立てる',
    );
    expect(result.snapshot.runMode, SafetyRunMode.unavailable);
    // 継続時間によらず音声は鳴らない。
    expect(result.snapshot.audioDirective, isNull);
    expect(result.snapshot.oneShotAudioCues, isEmpty);
  });

  test('GPS使用不能時は物理警告を3秒後に異常警告へ切り替える', () {
    final orchestrator = SafetyOrchestrator(
      sessionId: 'session-a',
      sessionGeneration: 1,
    );
    final danger = assessment([boatThreat('boat-a')]);
    orchestrator.processAssessment(
      assessment: danger,
      evaluatedAt: t0,
      capabilities: capabilities,
    );
    orchestrator.processAssessment(
      assessment: danger,
      evaluatedAt: t0.add(const Duration(seconds: 1)),
      capabilities: capabilities,
    );

    final gpsFault = AlertCandidate.stable(
      detectorId: 'gps_health',
      category: 'gps_unavailable',
      behavior: AlertBehavior.persistentSystemFault,
      evaluatedAt: t0.add(const Duration(seconds: 2)),
      observationId: 'gps-1',
      actionDeadline: Duration.zero,
      audioAsset: 'audio/other_boat_warning.mp3',
    );
    final unknown = orchestrator.processAssessment(
      assessment: assessment(const []),
      evaluatedAt: t0.add(const Duration(seconds: 2)),
      capabilities: const CapabilitySnapshot(
        gpsUsable: false,
        staticProfileUsable: true,
        audioUsable: true,
      ),
      dataQuality: AlertDataQuality.unusable,
      systemCandidates: [gpsFault],
    );
    expect(unknown.snapshot.activeAlerts, hasLength(3));
    expect(
      unknown.snapshot.activeAlerts.any(
        (alert) => alert.candidate.category == 'other_boat_track_lost',
      ),
      isTrue,
    );
    expect(unknown.state.primaryAlert!.candidate.category, 'other_boat');
    expect(unknown.snapshot.runMode, SafetyRunMode.unavailable);

    SafetyOrchestratorResult progressed = unknown;
    for (final seconds in [3, 4, 5]) {
      progressed = orchestrator.processAssessment(
        assessment: assessment(const []),
        evaluatedAt: t0.add(Duration(seconds: seconds)),
        capabilities: const CapabilitySnapshot(
          gpsUsable: false,
          staticProfileUsable: true,
          audioUsable: true,
        ),
        dataQuality: AlertDataQuality.unusable,
        systemCandidates: [
          gpsFault.copyWith(
            evaluatedAt: t0.add(Duration(seconds: seconds)),
            observationId: 'gps-$seconds',
          ),
        ],
      );
    }
    expect(
      progressed.snapshot.activeAlerts.any(
        (alert) => alert.candidate.category == 'other_boat',
      ),
      isFalse,
    );
    expect(
      progressed.snapshot.activeAlerts.any(
        (alert) => alert.candidate.category == 'gps_unavailable',
      ),
      isTrue,
    );
  });

  test('6〜10秒途絶したactive他艇は解除根拠にしない', () {
    final orchestrator = SafetyOrchestrator(
      sessionId: 'session-a',
      sessionGeneration: 1,
    );
    final danger = assessment([boatThreat('boat-a')]);
    orchestrator.processAssessment(
      assessment: danger,
      evaluatedAt: t0,
      capabilities: capabilities,
    );
    orchestrator.processAssessment(
      assessment: danger,
      evaluatedAt: t0.add(const Duration(seconds: 1)),
      capabilities: capabilities,
    );

    final lost = orchestrator.processAssessment(
      assessment: assessment(const []),
      evaluatedAt: t0.add(const Duration(seconds: 2)),
      capabilities: capabilities,
      unknownBoatIds: const {'boat-a'},
    );
    expect(lost.snapshot.activeAlerts, hasLength(2));
    final physical = lost.snapshot.activeAlerts.singleWhere(
      (alert) => alert.candidate.category == 'other_boat',
    );
    expect(physical.dataUnknown, isTrue);
    expect(
      lost.snapshot.activeAlerts.any(
        (alert) => alert.candidate.category == 'other_boat_track_lost',
      ),
      isTrue,
    );

    final stillHeld = orchestrator.processAssessment(
      assessment: assessment(const []),
      evaluatedAt: t0.add(const Duration(seconds: 3)),
      capabilities: capabilities,
    );
    expect(
      stillHeld.snapshot.activeAlerts.any(
        (alert) => alert.candidate.category == 'other_boat',
      ),
      isTrue,
    );
    expect(
      stillHeld.snapshot.activeAlerts
          .singleWhere((alert) => alert.candidate.category == 'other_boat')
          .dataUnknown,
      isTrue,
    );
  });

  test('active他艇が受信一覧から一気に消えても通信途絶として保持する', () {
    final orchestrator = SafetyOrchestrator(
      sessionId: 'session-a',
      sessionGeneration: 1,
    );
    final danger = assessment([boatThreat('boat-a')]);
    orchestrator.processAssessment(
      assessment: danger,
      evaluatedAt: t0,
      capabilities: capabilities,
      healthyBoatIds: const {'boat-a'},
    );
    orchestrator.processAssessment(
      assessment: danger,
      evaluatedAt: t0.add(const Duration(seconds: 1)),
      capabilities: capabilities,
      healthyBoatIds: const {'boat-a'},
    );

    // 受信層のTTL満了などでunknown一覧に残らず消えた状況を再現する。
    final lost = orchestrator.processAssessment(
      assessment: assessment(const []),
      evaluatedAt: t0.add(const Duration(seconds: 2)),
      capabilities: capabilities,
    );

    expect(
      lost.snapshot.activeAlerts.any(
        (alert) => alert.candidate.category == 'other_boat',
      ),
      isTrue,
    );
    expect(
      lost.snapshot.activeAlerts.any(
        (alert) => alert.candidate.category == 'other_boat_track_lost',
      ),
      isTrue,
    );
  });

  test('lost hold上限後は衝突音から通信途絶へ切り替える', () {
    final orchestrator = SafetyOrchestrator(
      sessionId: 'session-a',
      sessionGeneration: 1,
    );
    final danger = assessment([boatThreat('boat-a', entrySeconds: 5)]);
    orchestrator.processAssessment(
      assessment: danger,
      evaluatedAt: t0,
      capabilities: capabilities,
    );
    orchestrator.processAssessment(
      assessment: danger,
      evaluatedAt: t0.add(const Duration(seconds: 1)),
      capabilities: capabilities,
    );
    orchestrator.processAssessment(
      assessment: assessment(const []),
      evaluatedAt: t0.add(const Duration(seconds: 2)),
      capabilities: capabilities,
      unknownBoatIds: const {'boat-a'},
    );

    final afterHold = orchestrator.processAssessment(
      assessment: assessment(const []),
      evaluatedAt: t0.add(const Duration(seconds: 11)),
      capabilities: capabilities,
    );
    expect(
      afterHold.snapshot.activeAlerts.any(
        (alert) => alert.candidate.category == 'other_boat',
      ),
      isFalse,
    );
    expect(
      afterHold.state.primaryAlert!.candidate.category,
      'other_boat_track_lost',
    );
    // 途絶そのものは読み上げない。漕ぎながら対処できない情報を鳴らすと、
    // 本当に鳴るべき衝突警告を覆い隠す(原則4)。
    // 表示は `displayUntil` まで残るので、失われたことは分かる(原則1・6)。
    expect(afterHold.snapshot.audioDirective, isNull);
    expect(afterHold.snapshot.oneShotAudioCues, isEmpty);
  });

  test('途絶した他艇が安全な位置で復旧しても途絶表示を解除する', () {
    final orchestrator = SafetyOrchestrator(
      sessionId: 'session-a',
      sessionGeneration: 1,
    );
    final danger = assessment([boatThreat('boat-a')]);
    orchestrator.processAssessment(
      assessment: danger,
      evaluatedAt: t0,
      capabilities: capabilities,
    );
    orchestrator.processAssessment(
      assessment: danger,
      evaluatedAt: t0.add(const Duration(seconds: 1)),
      capabilities: capabilities,
    );
    orchestrator.processAssessment(
      assessment: assessment(const []),
      evaluatedAt: t0.add(const Duration(seconds: 2)),
      capabilities: capabilities,
      unknownBoatIds: const {'boat-a'},
    );

    final recovered = orchestrator.processAssessment(
      assessment: assessment(const []),
      evaluatedAt: t0.add(const Duration(seconds: 3)),
      capabilities: capabilities,
      healthyBoatIds: const {'boat-a'},
    );
    expect(
      recovered.state.alerts
          .singleWhere(
              (alert) => alert.candidate.category == 'other_boat_track_lost')
          .phase,
      AlertPhase.clearing,
    );
    expect(
      recovered.snapshot.activeAlerts
          .singleWhere((alert) => alert.candidate.category == 'other_boat')
          .dataUnknown,
      isFalse,
    );

    orchestrator.processAssessment(
      assessment: assessment(const []),
      evaluatedAt: t0.add(const Duration(seconds: 4)),
      capabilities: capabilities,
      healthyBoatIds: const {'boat-a'},
    );
    final cleared = orchestrator.processAssessment(
      assessment: assessment(const []),
      evaluatedAt: t0.add(const Duration(seconds: 6)),
      capabilities: capabilities,
      healthyBoatIds: const {'boat-a'},
    );
    expect(cleared.snapshot.activeAlerts, isEmpty);
  });

  test('カーブと逆走注意は両方activeで逆走を一回再生する', () {
    final orchestrator = SafetyOrchestrator(
      sessionId: 'session-guidance',
      sessionGeneration: 1,
    );
    RiskThreat guidance(StaticObstacleKind kind) => RiskThreat(
          level: CollisionRiskLevel.lv1,
          threat: ThreatInfo(
            kind: ThreatKind.obstacle,
            position: const LatLng(36, 140),
            obstacleKind: kind,
            obstacleId: kind.name,
          ),
        );

    final result = orchestrator.processAssessment(
      assessment: assessment([
        guidance(StaticObstacleKind.curve),
        guidance(StaticObstacleKind.reverse),
      ]),
      evaluatedAt: t0,
      capabilities: capabilities,
    );

    expect(result.snapshot.activeAlerts, hasLength(2));
    expect(result.state.primaryAlert?.candidate.category, 'reverse');
    expect(result.snapshot.audioDirective?.mode, AudioDirectiveMode.playOnce);
    expect(result.snapshot.audioDirective?.asset, 'audio/reverse_warning.mp3');
    expect(result.snapshot.audioDirective?.eventId, isNotNull);
  });

  test('固定障害物の音は到達時間で決まる(表示のみ/断続/連続)', () {
    // 以前は内部レベル(lv1/lv2/lv3)で音を決めていたため、
    // 「レベル」と「切迫度」が混線していた。現在は到達時間だけで決める。
    AlertBehavior behaviorFor(double entrySeconds) {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-static-$entrySeconds',
        sessionGeneration: 1,
      );
      final risk = assessment([
        staticThreat(
          'shore-band',
          level: CollisionRiskLevel.lv2,
          entrySeconds: entrySeconds,
        ),
      ]);
      orchestrator.processAssessment(
        assessment: risk,
        evaluatedAt: t0,
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 2,
      );
      final active = orchestrator.processAssessment(
        assessment: risk,
        evaluatedAt: t0.add(const Duration(seconds: 1)),
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 2,
      );
      expect(active.snapshot.activeAlerts, hasLength(1));
      return active.snapshot.activeAlerts.single.candidate.behavior;
    }

    // 断続音の予告地平(13秒)より先は表示のみ。
    expect(behaviorFor(14), AlertBehavior.visualOnly);
    // 主警告(10秒)の外側、13秒以内は断続音。
    expect(behaviorFor(12), AlertBehavior.singleAction);
    // 主警告の10秒以内は連続音。
    expect(behaviorFor(9), AlertBehavior.continuousAction);
  });
  test('連続音・断続音のバンド境界を設定で変えられる', () {
    // 到達までの時間だけで音を決める。内部レベルは参照しない。
    final orchestrator = SafetyOrchestrator(
      sessionId: 'session-thresholds',
      sessionGeneration: 1,
      presentationConfig: const AlertPresentationConfig(
        continuousAudioDeadline: Duration(seconds: 2),
        intermittentAudioDeadline: Duration(seconds: 8),
      ),
    );
    final risks = assessment([
      // 到達1秒 → 連続音バンド
      boatThreat(
        'boat-imminent',
        entrySeconds: 1,
        level: CollisionRiskLevel.lv3,
      ),
      // 到達5秒 → 断続音バンド
      staticThreat(
        'shore-approaching',
        level: CollisionRiskLevel.lv3,
        entrySeconds: 5,
      ),
    ]);
    orchestrator.processAssessment(
      assessment: risks,
      evaluatedAt: t0,
      capabilities: capabilities,
      ownSpeedMetersPerSecond: 2,
    );
    final active = orchestrator.processAssessment(
      assessment: risks,
      evaluatedAt: t0.add(const Duration(seconds: 1)),
      capabilities: capabilities,
      ownSpeedMetersPerSecond: 2,
    );

    final byCategory = {
      for (final alert in active.snapshot.activeAlerts)
        alert.candidate.category: alert.candidate,
    };
    expect(
      byCategory['other_boat']?.behavior,
      AlertBehavior.continuousAction,
    );
    expect(byCategory['shore']?.behavior, AlertBehavior.singleAction);
    expect(
      byCategory['shore']?.reasonCodes,
      contains('PRESENTATION_ACTION_INTERMITTENT'),
    );
  });

  test('内部レベルではなく到達時間で音を決める', () {
    // 同じ lv2 でも、到達が近ければ連続音、遠ければ表示のみになる。
    AlertBehavior behaviorFor(double entrySeconds) {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-band-$entrySeconds',
        sessionGeneration: 1,
      );
      final risks = assessment([
        staticThreat(
          'shore-band',
          level: CollisionRiskLevel.lv2,
          entrySeconds: entrySeconds,
        ),
      ]);
      orchestrator.processAssessment(
        assessment: risks,
        evaluatedAt: t0,
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 3,
      );
      final active = orchestrator.processAssessment(
        assessment: risks,
        evaluatedAt: t0.add(const Duration(seconds: 1)),
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 3,
      );
      return active.snapshot.activeAlerts.single.candidate.behavior;
    }

    expect(behaviorFor(5), AlertBehavior.continuousAction);
    expect(behaviorFor(11), AlertBehavior.singleAction);
    expect(behaviorFor(14), AlertBehavior.visualOnly);
  });

  test('橋も橋脚と同じ物理警告ロジックで切迫時は連続音にする', () {
    final orchestrator = SafetyOrchestrator(
      sessionId: 'session-bridge',
      sessionGeneration: 1,
    );
    final risks = assessment([
      staticThreat(
        'bridge-pass',
        kind: StaticObstacleKind.bridge,
        level: CollisionRiskLevel.lv3,
        entrySeconds: 2,
      ),
    ]);
    orchestrator.processAssessment(
      assessment: risks,
      evaluatedAt: t0,
      capabilities: capabilities,
      ownSpeedMetersPerSecond: 3,
    );
    final active = orchestrator.processAssessment(
      assessment: risks,
      evaluatedAt: t0.add(const Duration(seconds: 1)),
      capabilities: capabilities,
      ownSpeedMetersPerSecond: 3,
    );
    expect(
      active.snapshot.activeAlerts.single.candidate.behavior,
      AlertBehavior.continuousAction,
    );
  });

  test('確度が低い候補は1バンド下げて連続音の信頼性を守る', () {
    AlertBehavior behaviorFor(double confidence) {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-confidence-$confidence',
        sessionGeneration: 1,
      );
      final risks = assessment([
        staticThreat(
          'shore-confidence',
          level: CollisionRiskLevel.lv3,
          entrySeconds: 4,
          confidence: confidence == 1.0
              ? ThreatConfidence.definite
              : ThreatConfidence.uncertain,
        ),
      ]);
      orchestrator.processAssessment(
        assessment: risks,
        evaluatedAt: t0,
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 3,
      );
      final active = orchestrator.processAssessment(
        assessment: risks,
        evaluatedAt: t0.add(const Duration(seconds: 1)),
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 3,
      );
      return active.snapshot.activeAlerts.single.candidate.behavior;
    }

    expect(behaviorFor(1.0), AlertBehavior.continuousAction);
    expect(behaviorFor(0.7), AlertBehavior.singleAction);
  });

  test('安定停止5秒後は同一固定障害物の反復音を止め表示を維持する', () {
    final orchestrator = SafetyOrchestrator(
      sessionId: 'session-stopped',
      sessionGeneration: 1,
    );
    RiskAssessment dangerAt(double distance) => assessment([
          staticThreat(
            'shore-rest',
            level: CollisionRiskLevel.lv3,
            entrySeconds: 1,
            distanceMeters: distance,
          ),
        ]);

    final moving = orchestrator.processAssessment(
      assessment: dangerAt(10),
      evaluatedAt: t0,
      capabilities: capabilities,
      ownSpeedMetersPerSecond: 1,
    );
    expect(moving.snapshot.audioDirective?.mode, AudioDirectiveMode.loop);

    SafetyOrchestratorResult stopped = moving;
    for (var seconds = 1; seconds <= 6; seconds++) {
      stopped = orchestrator.processAssessment(
        assessment: dangerAt(10),
        evaluatedAt: t0.add(Duration(seconds: seconds)),
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 0.2,
      );
      if (seconds == 1) {
        expect(
          stopped.snapshot.audioDirective?.mode,
          AudioDirectiveMode.playOnce,
        );
      }
    }
    expect(stopped.snapshot.activeAlerts, hasLength(1));
    expect(
      stopped.snapshot.activeAlerts.single.candidate.behavior,
      AlertBehavior.visualOnly,
    );
    expect(stopped.snapshot.audioDirective, isNull);
  });

  test('安定停止中でも接近する他艇の緊急警告は反復を維持する', () {
    final orchestrator = SafetyOrchestrator(
      sessionId: 'session-stopped-other-boat',
      sessionGeneration: 1,
    );
    final risks = assessment([
      boatThreat(
        'approaching-boat',
        entrySeconds: 1,
        level: CollisionRiskLevel.lv3,
      ),
      staticThreat(
        'shore-rest',
        level: CollisionRiskLevel.lv3,
        entrySeconds: 1,
        distanceMeters: 8,
      ),
    ]);

    SafetyOrchestratorResult result = orchestrator.processAssessment(
      assessment: risks,
      evaluatedAt: t0,
      capabilities: capabilities,
      ownSpeedMetersPerSecond: 0.2,
    );
    for (var seconds = 1; seconds <= 6; seconds++) {
      result = orchestrator.processAssessment(
        assessment: risks,
        evaluatedAt: t0.add(Duration(seconds: seconds)),
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 0.2,
      );
    }

    final byCategory = {
      for (final alert in result.snapshot.activeAlerts)
        alert.candidate.category: alert.candidate.behavior,
    };
    expect(byCategory['shore'], AlertBehavior.visualOnly);
    expect(byCategory['other_boat'], AlertBehavior.continuousAction);
    expect(result.snapshot.audioDirective?.mode, AudioDirectiveMode.loop);
  });

  test('安定停止から再航行または2m接近すると同一脅威を再警告する', () {
    RiskAssessment dangerAt(double distance) => assessment([
          staticThreat(
            'shore-rest',
            level: CollisionRiskLevel.lv3,
            entrySeconds: 1,
            distanceMeters: distance,
          ),
        ]);

    final resumed = SafetyOrchestrator(
      sessionId: 'session-resume',
      sessionGeneration: 1,
    );
    resumed.processAssessment(
      assessment: dangerAt(10),
      evaluatedAt: t0,
      capabilities: capabilities,
      ownSpeedMetersPerSecond: 1,
    );
    for (var seconds = 1; seconds <= 6; seconds++) {
      resumed.processAssessment(
        assessment: dangerAt(10),
        evaluatedAt: t0.add(Duration(seconds: seconds)),
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 0.2,
      );
    }
    final movingAgain = resumed.processAssessment(
      assessment: dangerAt(10),
      evaluatedAt: t0.add(const Duration(seconds: 7)),
      capabilities: capabilities,
      ownSpeedMetersPerSecond: 1,
    );
    expect(movingAgain.snapshot.audioDirective?.mode, AudioDirectiveMode.loop);

    final drifting = SafetyOrchestrator(
      sessionId: 'session-drift',
      sessionGeneration: 1,
    );
    final driftInitial = drifting.processAssessment(
      assessment: dangerAt(10),
      evaluatedAt: t0,
      capabilities: capabilities,
      ownSpeedMetersPerSecond: 1,
    );
    for (var seconds = 1; seconds <= 6; seconds++) {
      drifting.processAssessment(
        assessment: dangerAt(10),
        evaluatedAt: t0.add(Duration(seconds: seconds)),
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 0.2,
      );
    }
    final closer = drifting.processAssessment(
      assessment: dangerAt(7.9),
      evaluatedAt: t0.add(const Duration(seconds: 7)),
      capabilities: capabilities,
      ownSpeedMetersPerSecond: 0.2,
    );
    expect(
      closer.snapshot.audioDirective?.mode,
      AudioDirectiveMode.playOnce,
    );
    expect(
      closer.snapshot.audioDirective?.eventId,
      isNot(driftInitial.snapshot.audioDirective?.eventId),
    );
  });

  test('危険区域内で低速になった直後から反復せず5秒後に無音表示へ移る', () {
    final orchestrator = SafetyOrchestrator(
      sessionId: 'session-low-speed-entry',
      sessionGeneration: 1,
    );
    final danger = assessment([
      staticThreat(
        'shore-low-speed',
        level: CollisionRiskLevel.lv3,
        entrySeconds: 0,
        distanceMeters: 8,
        overlap: true,
      ),
    ]);

    final first = orchestrator.processAssessment(
      assessment: danger,
      evaluatedAt: t0,
      capabilities: capabilities,
      ownSpeedMetersPerSecond: 0.2,
    );
    expect(first.snapshot.audioDirective?.mode, AudioDirectiveMode.playOnce);
    final eventId = first.snapshot.audioDirective?.eventId;

    final confirming = orchestrator.processAssessment(
      assessment: danger,
      evaluatedAt: t0.add(const Duration(seconds: 1)),
      capabilities: capabilities,
      ownSpeedMetersPerSecond: 0.2,
    );
    expect(
      confirming.snapshot.audioDirective?.mode,
      AudioDirectiveMode.playOnce,
    );
    expect(confirming.snapshot.audioDirective?.eventId, eventId);

    SafetyOrchestratorResult stable = confirming;
    for (var seconds = 2; seconds <= 5; seconds++) {
      stable = orchestrator.processAssessment(
        assessment: danger,
        evaluatedAt: t0.add(Duration(seconds: seconds)),
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 0.2,
      );
    }
    expect(
      stable.snapshot.activeAlerts.single.candidate.behavior,
      AlertBehavior.visualOnly,
    );
    expect(stable.snapshot.audioDirective, isNull);
  });

  test('安定停止中でも別の固定障害物へ遷移したときは単発警告する', () {
    final orchestrator = SafetyOrchestrator(
      sessionId: 'session-new-threat',
      sessionGeneration: 1,
    );
    final existing = staticThreat(
      'shore-existing',
      level: CollisionRiskLevel.lv3,
      entrySeconds: 1,
      distanceMeters: 10,
    );
    orchestrator.processAssessment(
      assessment: assessment([existing]),
      evaluatedAt: t0,
      capabilities: capabilities,
      ownSpeedMetersPerSecond: 1,
    );
    for (var seconds = 1; seconds <= 6; seconds++) {
      orchestrator.processAssessment(
        assessment: assessment([existing]),
        evaluatedAt: t0.add(Duration(seconds: seconds)),
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 0.2,
      );
    }

    final changedRisk = assessment([
      existing,
      staticThreat(
        'bridge-new',
        level: CollisionRiskLevel.lv2,
        entrySeconds: 4,
        distanceMeters: 12,
        kind: StaticObstacleKind.bridge,
      ),
    ]);
    orchestrator.processAssessment(
      assessment: changedRisk,
      evaluatedAt: t0.add(const Duration(seconds: 7)),
      capabilities: capabilities,
      ownSpeedMetersPerSecond: 0.2,
    );
    final changed = orchestrator.processAssessment(
      assessment: changedRisk,
      evaluatedAt: t0.add(const Duration(seconds: 8)),
      capabilities: capabilities,
      ownSpeedMetersPerSecond: 0.2,
    );

    expect(
      changed.state.primaryAlert?.candidate.targetId,
      'bridge-new',
    );
    expect(changed.snapshot.audioDirective?.mode, AudioDirectiveMode.playOnce);
  });

  test('安定停止中の同一脅威が短時間欠落しても単発イベントを作り直さない', () {
    final orchestrator = SafetyOrchestrator(
      sessionId: 'session-stable-jitter',
      sessionGeneration: 1,
    );
    final safe = assessment(const []);
    for (var seconds = 0; seconds <= 5; seconds++) {
      orchestrator.processAssessment(
        assessment: safe,
        evaluatedAt: t0.add(Duration(seconds: seconds)),
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 0.2,
      );
    }
    final threat = assessment([
      staticThreat(
        'bridge-jitter',
        level: CollisionRiskLevel.lv2,
        entrySeconds: 4,
        kind: StaticObstacleKind.bridge,
      ),
    ]);
    orchestrator.processAssessment(
      assessment: threat,
      evaluatedAt: t0.add(const Duration(seconds: 6)),
      capabilities: capabilities,
      ownSpeedMetersPerSecond: 0.2,
    );
    final announced = orchestrator.processAssessment(
      assessment: threat,
      evaluatedAt: t0.add(const Duration(seconds: 7)),
      capabilities: capabilities,
      ownSpeedMetersPerSecond: 0.2,
    );
    final eventId = announced.snapshot.audioDirective?.eventId;
    expect(eventId, isNotNull);

    orchestrator.processAssessment(
      assessment: safe,
      evaluatedAt: t0.add(const Duration(seconds: 8)),
      capabilities: capabilities,
      ownSpeedMetersPerSecond: 0.2,
    );
    final returned = orchestrator.processAssessment(
      assessment: threat,
      evaluatedAt: t0.add(const Duration(seconds: 9)),
      capabilities: capabilities,
      ownSpeedMetersPerSecond: 0.2,
    );

    expect(returned.snapshot.audioDirective?.eventId, eventId);
  });

  // 逆走の再武装は60秒(reverseGuidanceRearmDuration)なので、
  // 5秒の再武装はカーブで確かめる。
  test('案内区域は進入1回だけ通知し退出5秒後に再装填する', () {
    final orchestrator = SafetyOrchestrator(
      sessionId: 'session-guidance-rearm',
      sessionGeneration: 1,
    );
    final inside = assessment([
      RiskThreat(
        level: CollisionRiskLevel.lv1,
        threat: ThreatInfo(
          kind: ThreatKind.obstacle,
          position: const LatLng(36, 140),
          obstacleKind: StaticObstacleKind.curve,
          obstacleId: 'curve-a',
        ),
      ),
    ]);
    final outside = assessment(const []);

    final firstEntry = orchestrator.processAssessment(
      assessment: inside,
      evaluatedAt: t0,
      capabilities: capabilities,
      ownSpeedMetersPerSecond: 1,
    );
    final firstEvent = firstEntry.snapshot.audioDirective?.eventId;
    expect(
        firstEntry.snapshot.audioDirective?.mode, AudioDirectiveMode.playOnce);

    final staying = orchestrator.processAssessment(
      assessment: inside,
      evaluatedAt: t0.add(const Duration(seconds: 1)),
      capabilities: capabilities,
      ownSpeedMetersPerSecond: 1,
    );
    expect(staying.snapshot.audioDirective?.eventId, firstEvent);

    orchestrator.processAssessment(
      assessment: outside,
      evaluatedAt: t0.add(const Duration(seconds: 2)),
      capabilities: capabilities,
      ownSpeedMetersPerSecond: 1,
    );
    final tooSoon = orchestrator.processAssessment(
      assessment: inside,
      evaluatedAt: t0.add(const Duration(seconds: 4)),
      capabilities: capabilities,
      ownSpeedMetersPerSecond: 1,
    );
    expect(tooSoon.snapshot.audioDirective, isNull);
    expect(tooSoon.snapshot.activeAlerts, hasLength(1));

    orchestrator.processAssessment(
      assessment: outside,
      evaluatedAt: t0.add(const Duration(seconds: 5)),
      capabilities: capabilities,
      ownSpeedMetersPerSecond: 1,
    );
    for (var seconds = 6; seconds < 10; seconds++) {
      orchestrator.processAssessment(
        assessment: outside,
        evaluatedAt: t0.add(Duration(seconds: seconds)),
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 1,
      );
    }
    final reentered = orchestrator.processAssessment(
      assessment: inside,
      evaluatedAt: t0.add(const Duration(seconds: 10)),
      capabilities: capabilities,
      ownSpeedMetersPerSecond: 1,
    );
    expect(
        reentered.snapshot.audioDirective?.mode, AudioDirectiveMode.playOnce);
    expect(reentered.snapshot.audioDirective?.eventId, isNot(firstEvent));
  });

  // ---- 近接注意(到達予測なし)の鳴らし方 ----

  /// 到達予測を持たない近接注意の候補。
  RiskThreat proximityThreat(
    String id, {
    required StaticObstacleKind kind,
    required double distanceMeters,
  }) =>
      RiskThreat(
        level: CollisionRiskLevel.lv1,
        threat: ThreatInfo(
          kind: ThreatKind.obstacle,
          position: const LatLng(36.0, 140.0),
          obstacleKind: kind,
          obstacleId: id,
          distanceMeters: distanceMeters,
        ),
      );

  /// 2観測1秒を満たしてactiveにしたうえで、提示された候補を返す。
  AlertCandidate presentProximity({
    required StaticObstacleKind kind,
    required List<double> distances,
  }) {
    final orchestrator = SafetyOrchestrator(
      sessionId: 'session-proximity-${kind.name}',
      sessionGeneration: 1,
    );
    late SafetyOrchestratorResult result;
    for (var index = 0; index < distances.length; index++) {
      result = orchestrator.processAssessment(
        assessment: assessment([
          proximityThreat(
            'zone',
            kind: kind,
            distanceMeters: distances[index],
          ),
        ]),
        evaluatedAt: t0.add(Duration(seconds: index)),
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 2,
      );
    }
    return result.snapshot.activeAlerts.single.candidate;
  }

  test('岸への近接注意は鳴らさない(川幅40mでは常に近く形骸化する)', () {
    final candidate = presentProximity(
      kind: StaticObstacleKind.shore,
      distances: [8, 6, 4],
    );
    expect(candidate.behavior, AlertBehavior.visualOnly);
    expect(candidate.audioAsset, isNull);
  });

  test('中州への近接は流木と同様に鳴らす', () {
    final candidate = presentProximity(
      kind: StaticObstacleKind.island,
      distances: [8, 6],
    );
    expect(candidate.behavior, AlertBehavior.singleAction);
    expect(candidate.audioAsset, isNotNull);
  });

  test('流木への近接は接近中に鳴らすが、同じ接近では鳴り直さない', () {
    final orchestrator = SafetyOrchestrator(
      sessionId: 'session-driftwood',
      sessionGeneration: 1,
    );
    AlertCandidate step(double distance, int second) {
      final result = orchestrator.processAssessment(
        assessment: assessment([
          proximityThreat(
            'driftwood',
            kind: StaticObstacleKind.driftwood,
            distanceMeters: distance,
          ),
        ]),
        evaluatedAt: t0.add(Duration(seconds: second)),
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 2,
      );
      final active = result.snapshot.activeAlerts;
      return active.isEmpty
          ? result.state.alerts.single.candidate
          : active.single.candidate;
    }

    step(8, 0);
    final first = step(6, 1);
    expect(first.behavior, AlertBehavior.singleAction);
    expect(first.audioAsset, isNotNull);

    // 近づき続けても音声イベントIDは変わらない = 再生は1回だけ。
    expect(step(5, 2).audioEventId, first.audioEventId);
    expect(step(4, 3).audioEventId, first.audioEventId);
  });

  test('流木から離れてから再接近すると新しい音として鳴り直す', () {
    final orchestrator = SafetyOrchestrator(
      sessionId: 'session-proximity-rearm',
      sessionGeneration: 1,
    );
    AlertCandidate step(double distance, int second) {
      final result = orchestrator.processAssessment(
        assessment: assessment([
          proximityThreat(
            'driftwood',
            kind: StaticObstacleKind.driftwood,
            distanceMeters: distance,
          ),
        ]),
        evaluatedAt: t0.add(Duration(seconds: second)),
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 2,
      );
      final active = result.snapshot.activeAlerts;
      return active.isEmpty
          ? result.state.alerts.single.candidate
          : active.single.candidate;
    }

    step(8, 0);
    final approach = step(5, 1);
    expect(approach.behavior, AlertBehavior.singleAction);
    final firstEventId = approach.audioEventId;
    expect(firstEventId, isNotNull);

    // 再武装には最接近点から3m以上離れる必要がある。
    expect(step(7, 2).audioEventId, firstEventId);

    // 十分離れたので新しいエピソードになる。
    step(9, 3);
    final reapproach = step(8, 4);
    expect(reapproach.behavior, AlertBehavior.singleAction);
    expect(reapproach.audioEventId, isNot(firstEventId));
  });

  test('断続音は間隔ごとに新しい音声イベントへ切り替わる', () {
    final orchestrator = SafetyOrchestrator(
      sessionId: 'session-intermittent',
      sessionGeneration: 1,
    );
    // 到達12秒 = 断続音バンド（主警告10秒・予告13秒）。
    final risk = assessment([
      staticThreat('shore-rep',
          level: CollisionRiskLevel.lv2, entrySeconds: 12),
    ]);
    String? eventAt(int second) {
      final result = orchestrator.processAssessment(
        assessment: risk,
        evaluatedAt: t0.add(Duration(seconds: second)),
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 3,
      );
      final active = result.snapshot.activeAlerts;
      return active.isEmpty ? null : active.single.candidate.audioEventId;
    }

    eventAt(0);
    final first = eventAt(1);
    expect(first, isNotNull);
    // 間隔(3秒)未満では同じイベントのまま = 鳴り直さない。
    expect(eventAt(2), first);
    // 最初の提示から3秒で鳴らし直す。
    final second = eventAt(3);
    expect(second, isNotNull);
    expect(second, isNot(first));
    expect(eventAt(4), second);
    expect(eventAt(5), second);
    // さらに3秒でもう一度。
    expect(eventAt(6), isNot(second));
  });
}
