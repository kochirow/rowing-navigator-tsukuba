import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/models/alert_candidate.dart';
import 'package:rowing_navigator/models/safety_snapshot.dart';
import 'package:rowing_navigator/models/static_obstacle_model.dart';
import 'package:rowing_navigator/services/collision_risk_evaluator_service.dart';
import 'package:rowing_navigator/services/continuous_collision_service.dart';
import 'package:rowing_navigator/services/safety_orchestrator.dart';
import 'package:rowing_navigator/types/collision_risk_level.dart';

/// 実機ログ(2026-07-26)で判明した過剰警告・無発報への対策を固定する。
///
/// 対象は3つ。
/// 1. 重なりの切迫度を接近速度で判定する(原則5)
/// 2. 静的警告を生成元の基準線(sourceId)へ集約する
/// 3. 音声チャンネルを表示primaryから分離する(原則1・原則4)
void main() {
  final t0 = DateTime.utc(2026, 7, 26, 9);
  const capabilities = CapabilitySnapshot(
    gpsUsable: true,
    staticProfileUsable: true,
    insideSupportedCoverage: true,
    audioUsable: true,
  );

  RiskAssessment assessment(Iterable<RiskThreat> threats) => RiskAssessment(
        level:
            threats.isEmpty ? CollisionRiskLevel.lv0 : CollisionRiskLevel.lv2,
        primaryThreat: threats.isEmpty ? null : threats.first.threat,
        threats: threats,
      );

  /// 静的危険区域の脅威。[sourceId] を渡すと集約の対象になる。
  RiskThreat staticThreat({
    required String obstacleId,
    String? sourceId,
    String? bridgeId,
    StaticObstacleKind kind = StaticObstacleKind.shore,
    bool overlap = false,
    double? distanceMeters,
    double? entrySeconds,
  }) =>
      RiskThreat(
        level: CollisionRiskLevel.lv2,
        threat: ThreatInfo(
          kind: ThreatKind.obstacle,
          position: const LatLng(36.0, 140.0),
          obstacleKind: kind,
          obstacleId: obstacleId,
          obstacleSourceId: sourceId,
          obstacleBridgeId: bridgeId,
          distanceMeters: distanceMeters,
          continuousIntersection: ContinuousIntersection(
            intersects: true,
            currentOverlap: overlap,
            firstEntryTimeSeconds: overlap ? 0 : entrySeconds,
            firstExitTimeSeconds: (entrySeconds ?? 0) + 2,
            // distanceMeters を null にしたい場合はここも埋めない。
            firstEntryDistanceMeters: null,
            minimumSeparationMeters: 0,
          ),
        ),
      );

  RiskThreat boatThreat({
    required String boatId,
    bool overlap = true,
    double? distanceMeters,
  }) =>
      RiskThreat(
        level: CollisionRiskLevel.lv3,
        threat: ThreatInfo(
          kind: ThreatKind.boat,
          position: const LatLng(36.0, 140.0),
          boatId: boatId,
          distanceMeters: distanceMeters,
          continuousIntersection: ContinuousIntersection(
            intersects: true,
            currentOverlap: overlap,
            firstEntryTimeSeconds: 0,
            firstExitTimeSeconds: 2,
            minimumSeparationMeters: 0,
          ),
        ),
      );

  AlertCandidate systemFault({
    required String detectorId,
    required String category,
    required DateTime at,
    String? audioAsset,
  }) =>
      AlertCandidate.stable(
        detectorId: detectorId,
        category: category,
        behavior: AlertBehavior.persistentSystemFault,
        evaluatedAt: at,
        observationId: '$detectorId:${at.microsecondsSinceEpoch}',
        actionDeadline: Duration.zero,
        audioAsset: audioAsset,
      );

  RiskThreat guidanceThreat(
    StaticObstacleKind kind, {
    String? obstacleId,
    bool reverseDirectionConfirmed = false,
  }) =>
      RiskThreat(
        level: CollisionRiskLevel.lv1,
        threat: ThreatInfo(
          kind: ThreatKind.obstacle,
          position: const LatLng(36.0, 140.0),
          obstacleKind: kind,
          obstacleId: obstacleId ?? kind.name,
          continuousIntersection: reverseDirectionConfirmed
              ? ContinuousIntersection(
                  intersects: true,
                  currentOverlap: true,
                  firstEntryTimeSeconds: null,
                  firstExitTimeSeconds: null,
                  minimumSeparationMeters: 0,
                  reasonCodes: const ['reverse_direction_confirmed'],
                )
              : null,
        ),
      );

  // ---- 1. 重なりの切迫度を接近速度で判定する ----

  group('重なりの切迫度', () {
    test('重なったまま距離が縮まらなければ連続音にならず猶予後は表示のみになる', () {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-steady-overlap',
        sessionGeneration: 1,
      );
      AlertCandidate step(int second) {
        final result = orchestrator.processAssessment(
          assessment: assessment([
            staticThreat(
              obstacleId: 'shore_north_65',
              sourceId: 'shore_north',
              overlap: true,
              distanceMeters: 3,
            ),
          ]),
          evaluatedAt: t0.add(Duration(seconds: second)),
          capabilities: capabilities,
          // 岸と並走している。停止していないので既存の安定停止抑制は働かない。
          ownSpeedMetersPerSecond: 4,
        );
        return result.snapshot.activeAlerts.single.candidate;
      }

      // 初回は接近速度を求められない。データ欠損を安全の根拠にしない(原則6)。
      expect(step(0).behavior, AlertBehavior.continuousAction);

      final steady = step(1);
      expect(steady.behavior, AlertBehavior.singleAction);
      expect(
        steady.reasonCodes,
        contains('PRESENTATION_STEADY_OVERLAP_INTERMITTENT'),
      );

      for (var second = 2; second <= 5; second++) {
        expect(step(second).behavior, AlertBehavior.singleAction);
      }

      // 縮まらないまま猶予(5秒)を過ぎたら表示だけにする。
      final silent = step(6);
      expect(silent.behavior, AlertBehavior.visualOnly);
      expect(
        silent.reasonCodes,
        contains('PRESENTATION_STEADY_OVERLAP_SILENT'),
      );
    });

    test('重なったまま2m再接近したら連続音へ戻る', () {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-overlap-rearm',
        sessionGeneration: 1,
      );
      AlertCandidate step(int second, double distance) {
        final result = orchestrator.processAssessment(
          assessment: assessment([
            staticThreat(
              obstacleId: 'shore_north_65',
              sourceId: 'shore_north',
              overlap: true,
              distanceMeters: distance,
            ),
          ]),
          evaluatedAt: t0.add(Duration(seconds: second)),
          capabilities: capabilities,
          ownSpeedMetersPerSecond: 4,
        );
        return result.snapshot.activeAlerts.single.candidate;
      }

      for (var second = 0; second <= 6; second++) {
        step(second, 3);
      }
      expect(step(6, 3).behavior, AlertBehavior.visualOnly);

      // しきい値(0.3m/s)未満のじわじわした接近。基準距離から2m縮むまで
      // 連続音には戻らない。
      AlertCandidate? last;
      for (var index = 1; index <= 9; index++) {
        last = step(6 + index, 3 - 0.2 * index);
        expect(last.behavior, isNot(AlertBehavior.continuousAction));
      }
      expect(last, isNotNull);

      // 3.0 → 1.0 で2m。ここで再武装する。
      expect(step(16, 1.0).behavior, AlertBehavior.continuousAction);
    });

    test('距離が取れないまま重なっているときは連続音を維持する', () {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-overlap-no-distance',
        sessionGeneration: 1,
      );
      for (var second = 0; second <= 8; second++) {
        final result = orchestrator.processAssessment(
          assessment: assessment([
            staticThreat(
              obstacleId: 'shore_north_65',
              sourceId: 'shore_north',
              overlap: true,
            ),
          ]),
          evaluatedAt: t0.add(Duration(seconds: second)),
          capabilities: capabilities,
          ownSpeedMetersPerSecond: 4,
        );
        final candidate = result.snapshot.activeAlerts.single.candidate;
        expect(candidate.distanceMeters, isNull);
        // データ欠損は安全の根拠にならない(原則6)。
        expect(candidate.behavior, AlertBehavior.continuousAction);
      }
    });

    test('他艇は距離が縮まらなくても連続音を維持する', () {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-overlap-other-boat',
        sessionGeneration: 1,
      );
      for (var second = 0; second <= 8; second++) {
        final result = orchestrator.processAssessment(
          assessment: assessment([
            boatThreat(boatId: 'boat-a', distanceMeters: 3),
          ]),
          evaluatedAt: t0.add(Duration(seconds: second)),
          capabilities: capabilities,
          ownSpeedMetersPerSecond: 4,
        );
        // 相手が接近してくるため、他艇は抑制の対象にしない。
        expect(
          result.snapshot.activeAlerts.single.candidate.behavior,
          AlertBehavior.continuousAction,
        );
      }
    });
  });

  // ---- 2. sourceId 単位の集約 ----

  group('sourceId集約', () {
    test('同じ基準線の複数の辺は1つの警告へまとまる', () {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-source-aggregation',
        sessionGeneration: 1,
      );
      final risks = assessment([
        staticThreat(
          obstacleId: 'shore_north_65',
          sourceId: 'shore_north',
          distanceMeters: 9,
          entrySeconds: 5,
        ),
        staticThreat(
          obstacleId: 'shore_north_66',
          sourceId: 'shore_north',
          distanceMeters: 4,
          entrySeconds: 3,
        ),
        staticThreat(
          obstacleId: 'shore_north_67',
          sourceId: 'shore_north',
          distanceMeters: 6,
          entrySeconds: 4,
        ),
      ]);
      final result = orchestrator.processAssessment(
        assessment: risks,
        evaluatedAt: t0,
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 4,
      );

      expect(result.snapshot.activeAlerts, hasLength(1));
      final candidate = result.snapshot.activeAlerts.single.candidate;
      expect(candidate.targetId, 'shore_north');
      expect(candidate.alertId, contains('shore_north'));
      // 代表になった辺は診断ログから追えるよう理由コードに残す。
      expect(candidate.reasonCodes, contains('SOURCE_EDGE:shore_north_66'));
    });

    test('橋の手前の面と奥の面を通過しても音声エピソードは1回だけ', () {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-bridge-pass',
        sessionGeneration: 1,
      );
      // 手前の面(_0)へ近づき、抜けたあと奥の面(_2)が重なる。
      // 集約前は _0 と _2 で2回鳴っていた(橋の真下での再発音)。
      const nearFace = [30.0, 20.0, 12.0, 6.0, 2.0];
      const nearEntry = [6.0, 5.0, 4.0, 3.0, 2.0];
      const farFace = [60.0, 50.0, 40.0, 30.0, 20.0];
      const exitFace = [6.0, 3.0, -1.0];
      const exitEntry = [6.0, 3.0, 0.0];

      final eventIds = <String>{};
      final alertIds = <String>{};
      void observe(SafetyOrchestratorResult result) {
        for (final alert in result.snapshot.activeAlerts) {
          alertIds.add(alert.candidate.alertId);
          final eventId = alert.candidate.audioEventId;
          if (eventId != null) eventIds.add(eventId);
        }
      }

      for (var index = 0; index < nearFace.length; index++) {
        observe(orchestrator.processAssessment(
          assessment: assessment([
            staticThreat(
              obstacleId: 'bridge_railway_0',
              sourceId: 'bridge_railway',
              kind: StaticObstacleKind.bridge,
              distanceMeters: nearFace[index],
              entrySeconds: nearEntry[index],
            ),
            staticThreat(
              obstacleId: 'bridge_railway_2',
              sourceId: 'bridge_railway',
              kind: StaticObstacleKind.bridge,
              distanceMeters: farFace[index],
              entrySeconds: 10,
            ),
          ]),
          evaluatedAt: t0.add(Duration(seconds: index)),
          capabilities: capabilities,
          ownSpeedMetersPerSecond: 4,
        ));
      }
      for (var index = 0; index < exitFace.length; index++) {
        observe(orchestrator.processAssessment(
          assessment: assessment([
            staticThreat(
              obstacleId: 'bridge_railway_2',
              sourceId: 'bridge_railway',
              kind: StaticObstacleKind.bridge,
              distanceMeters: exitFace[index],
              entrySeconds: exitEntry[index],
              overlap: exitFace[index] < 0,
            ),
          ]),
          evaluatedAt: t0.add(Duration(seconds: 5 + index)),
          capabilities: capabilities,
          ownSpeedMetersPerSecond: 4,
        ));
      }

      expect(alertIds, hasLength(1));
      expect(eventIds, hasLength(1));
    });

    test('同じ橋の左右の橋脚は最も切迫した1件へ集約する', () {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-pier-aggregation',
        sessionGeneration: 1,
      );
      final result = orchestrator.processAssessment(
        assessment: assessment([
          staticThreat(
            obstacleId: 'bridgepier_nioi_1',
            bridgeId: 'bridge_nioi',
            kind: StaticObstacleKind.bridgePier,
            distanceMeters: 8,
            entrySeconds: 8,
          ),
          staticThreat(
            obstacleId: 'bridgepier_nioi_2',
            bridgeId: 'bridge_nioi',
            kind: StaticObstacleKind.bridgePier,
            distanceMeters: 2,
            entrySeconds: 3,
          ),
        ]),
        evaluatedAt: t0,
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 4,
      );

      expect(result.snapshot.activeAlerts, hasLength(1));
      final pier = result.snapshot.activeAlerts.single.candidate;
      expect(pier.targetId, 'bridge_nioi');
      expect(pier.behavior, AlertBehavior.continuousAction);
      expect(pier.audioAsset, 'audio/bridge_pier_warning.mp3');
    });
  });

  // ---- 3. 音声チャンネルの分離 ----

  group('音声チャンネル', () {
    test('衝突警告が鳴っている間はカーブを重ねて鳴らさない', () {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-guidance-yields',
        sessionGeneration: 1,
      );
      final result = orchestrator.processAssessment(
        assessment: assessment([
          boatThreat(boatId: 'boat-a'),
          guidanceThreat(StaticObstacleKind.curve),
        ]),
        evaluatedAt: t0,
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 4,
      );

      // 持続音は他艇が握る(continuousAction=band0 対 entryEvent=band3)。
      expect(result.snapshot.audioDirective?.asset,
          'audio/other_boat_warning.mp3');
      // カーブは2本目のプレイヤーへ回さない。重ねて鳴らすと
      // 「他艇に注意」と「カーブに注意」が混ざって両方聞き取れなくなる。
      expect(result.snapshot.oneShotAudioCues, isEmpty);
    });

    test('衝突警告が消えたらカーブの読み上げが戻る', () {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-guidance-resumes',
        sessionGeneration: 1,
      );
      SafetyOrchestratorResult step(int second, {required bool boat}) =>
          orchestrator.processAssessment(
            assessment: assessment([
              if (boat) boatThreat(boatId: 'boat-a'),
              guidanceThreat(StaticObstacleKind.curve),
            ]),
            evaluatedAt: t0.add(Duration(seconds: second)),
            capabilities: capabilities,
            ownSpeedMetersPerSecond: 4,
          );

      step(0, boat: true);
      // 他艇の警告が解除(clearing)を終えたら、カーブが持続音チャンネルを
      // 取り戻す。解除待ちの間はまだ他艇が握っている(FSMの正常な挙動)。
      String? asset;
      for (var second = 1; second <= 20; second++) {
        asset = step(second, boat: false).snapshot.audioDirective?.asset;
        if (asset == 'audio/curve_warning.mp3') break;
      }
      expect(asset, 'audio/curve_warning.mp3');
    });

    test('system faultの音声資産は無効化し物理警告を邪魔しない', () {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-cue-with-fault',
        sessionGeneration: 1,
      );
      final result = orchestrator.processAssessment(
        assessment: assessment([guidanceThreat(StaticObstacleKind.curve)]),
        evaluatedAt: t0,
        capabilities: capabilities,
        systemCandidates: [
          systemFault(
            detectorId: 'gps_health',
            category: 'gps_unavailable',
            at: t0,
            audioAsset: 'audio/system_fault_warning.mp3',
          ),
        ],
        ownSpeedMetersPerSecond: 4,
      );

      expect(result.snapshot.audioDirective?.asset, 'audio/curve_warning.mp3');
      expect(result.snapshot.oneShotAudioCues, isEmpty);
      expect(
        result.snapshot.activeAlerts
            .firstWhere(
                (alert) => alert.candidate.category == 'gps_unavailable')
            .candidate
            .audioAsset,
        isNull,
      );
    });

    test('無音のsystem faultが表示primaryでも鳴っている持続音を消さない', () {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-silent-fault',
        sessionGeneration: 1,
      );
      final result = orchestrator.processAssessment(
        assessment: assessment([guidanceThreat(StaticObstacleKind.reverse)]),
        evaluatedAt: t0,
        capabilities: capabilities,
        systemCandidates: [
          // 実機で216回 primary になり、そのたびに音を止めていた候補。
          systemFault(
            detectorId: 'operational_coverage',
            category: 'operational_coverage_unverified',
            at: t0,
          ),
        ],
        ownSpeedMetersPerSecond: 4,
      );

      expect(
        result.state.primaryAlert?.candidate.category,
        'operational_coverage_unverified',
      );
      // 表示primaryが無音でも、音声の対象は独立に選ばれる。
      expect(result.snapshot.audioDirective, isNotNull);
      expect(
        result.snapshot.audioDirective!.asset,
        'audio/reverse_warning.mp3',
      );
    });

    test('system faultは確定時も5分後も無音で表示を維持する', () {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-visual-first-fault',
        sessionGeneration: 1,
      );
      SafetyOrchestratorResult step(int second) =>
          orchestrator.processAssessment(
            assessment: assessment(const []),
            evaluatedAt: t0.add(Duration(seconds: second)),
            capabilities: const CapabilitySnapshot(
              gpsUsable: true,
              staticProfileUsable: true,
              insideSupportedCoverage: true,
              audioUsable: true,
              dynamicReceiveUsable: false,
            ),
            systemCandidates: [
              systemFault(
                detectorId: 'dynamic_receive',
                category: 'other_boat_receive_unavailable',
                at: t0.add(Duration(seconds: second)),
                audioAsset: 'audio/other_boat_warning.mp3',
              ),
            ],
          );

      final confirmed = step(0);
      expect(confirmed.snapshot.audioDirective, isNull);
      expect(confirmed.snapshot.oneShotAudioCues, isEmpty);

      for (var second = 1; second <= 5; second++) {
        final quiet = step(second);
        expect(quiet.snapshot.oneShotAudioCues, isEmpty);
        expect(quiet.snapshot.audioDirective, isNull);
        // 表示は消さない(原則1・原則6)。
        expect(
          quiet.snapshot.activeAlerts.single.candidate.category,
          'other_boat_receive_unavailable',
        );
        expect(quiet.snapshot.visualDirective.orderedAlertIds, hasLength(1));
      }

      final justBefore = step(299);
      expect(justBefore.snapshot.oneShotAudioCues, isEmpty);

      final recued = step(300);
      expect(recued.snapshot.oneShotAudioCues, isEmpty);
      expect(recued.snapshot.audioDirective, isNull);
      expect(recued.snapshot.visualDirective.orderedAlertIds, hasLength(1));
    });

    test('読み上げは同時に2本鳴らさない(橋と他艇が重なっても1本)', () {
      // 全アセットが読み上げ音声になったので、2本流すと
      // どちらも聞き取れない。1本を確実に伝えるほうが良い。
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-no-overlap',
        sessionGeneration: 1,
      );
      SafetyOrchestratorResult step(int second) =>
          orchestrator.processAssessment(
            assessment: assessment([
              boatThreat(boatId: 'boat-a'),
              staticThreat(
                obstacleId: 'bridge_main',
                sourceId: 'bridge_main',
                kind: StaticObstacleKind.bridge,
                entrySeconds: 3,
              ),
            ]),
            evaluatedAt: t0.add(Duration(seconds: second)),
            capabilities: capabilities,
            ownSpeedMetersPerSecond: 4,
          );

      for (var second = 0; second <= 5; second++) {
        final snapshot = step(second).snapshot;
        expect(
          snapshot.oneShotAudioCues,
          isEmpty,
          reason: '$second秒: 2本目のプレイヤーへ回すと読み上げが重なる',
        );
        // 持続音チャンネルは常に1本だけ。
        expect(snapshot.audioDirective, isNotNull);
      }
    });

    test('橋だけなら持続音チャンネルで鳴る(取り合いに負けて消えない)', () {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-bridge-alone',
        sessionGeneration: 1,
      );
      SafetyOrchestratorResult step(int second) =>
          orchestrator.processAssessment(
            assessment: assessment([
              staticThreat(
                obstacleId: 'bridge_main',
                sourceId: 'bridge_main',
                kind: StaticObstacleKind.bridge,
                entrySeconds: 3,
              ),
            ]),
            evaluatedAt: t0.add(Duration(seconds: second)),
            capabilities: capabilities,
            ownSpeedMetersPerSecond: 4,
          );

      step(0);
      final result = step(1);
      expect(
        result.snapshot.audioDirective?.asset,
        'audio/bridge_warning.mp3',
      );
      // 橋も橋脚と同じ物理警告ロジックを使う。
      expect(
        result.snapshot.audioDirective?.mode,
        AudioDirectiveMode.loop,
      );
    });

    test('区域内にいる間はカーブを5秒ごとに読み上げ直す', () {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-guidance-repeat',
        sessionGeneration: 1,
      );
      AlertCandidate step(int second) => orchestrator
          .processAssessment(
            assessment: assessment([guidanceThreat(StaticObstacleKind.curve)]),
            evaluatedAt: t0.add(Duration(seconds: second)),
            capabilities: capabilities,
            ownSpeedMetersPerSecond: 4,
          )
          .snapshot
          .activeAlerts
          .single
          .candidate;

      // 1回だけでは聞き逃す。区域内にいる限り鳴らし直す。
      final entryId = step(0).audioEventId;
      expect(entryId, isNotNull);
      expect(step(0).reasonCodes, contains('GUIDANCE_ENTRY'));

      // 5秒経つまでは同じイベントID = 鳴り直さない。
      for (var second = 1; second <= 4; second++) {
        expect(step(second).audioEventId, entryId);
      }

      final firstRepeat = step(5);
      expect(firstRepeat.audioEventId, isNot(entryId));
      expect(firstRepeat.reasonCodes, contains('GUIDANCE_REPEAT'));
      // 資産は変わらない。同じ読み上げをもう一度鳴らすだけ。
      expect(firstRepeat.audioAsset, 'audio/curve_warning.mp3');

      for (var second = 6; second <= 9; second++) {
        expect(step(second).audioEventId, firstRepeat.audioEventId);
      }
      expect(step(10).audioEventId, isNot(firstRepeat.audioEventId));
    });

    test('衝突警告に負けている間もカーブの周期は進み、復帰後に鳴り直す', () {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-guidance-repeat-yield',
        sessionGeneration: 1,
      );
      SafetyOrchestratorResult step(int second, {required bool boat}) =>
          orchestrator.processAssessment(
            assessment: assessment([
              if (boat) boatThreat(boatId: 'boat-a'),
              guidanceThreat(StaticObstacleKind.curve),
            ]),
            evaluatedAt: t0.add(Duration(seconds: second)),
            capabilities: capabilities,
            ownSpeedMetersPerSecond: 4,
          );

      step(0, boat: false);
      // 他艇が現れている間、カーブは無音(重ねない)。
      for (var second = 1; second <= 6; second++) {
        final result = step(second, boat: true);
        expect(result.snapshot.oneShotAudioCues, isEmpty);
        expect(
          result.snapshot.audioDirective?.asset,
          'audio/other_boat_warning.mp3',
        );
      }
      // 他艇の解除が済んだら、進んでいた周期のイベントIDで読み上げが戻る。
      String? asset;
      for (var second = 7; second <= 26; second++) {
        asset = step(second, boat: false).snapshot.audioDirective?.asset;
        if (asset == 'audio/curve_warning.mp3') break;
      }
      expect(asset, 'audio/curve_warning.mp3');
    });

    test('区域を出れば周期は止まり、再進入で1回目から始まる', () {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-guidance-exit',
        sessionGeneration: 1,
      );
      SafetyOrchestratorResult step(int second, {required bool inside}) =>
          orchestrator.processAssessment(
            assessment: assessment(
              inside ? [guidanceThreat(StaticObstacleKind.curve)] : const [],
            ),
            evaluatedAt: t0.add(Duration(seconds: second)),
            capabilities: capabilities,
            ownSpeedMetersPerSecond: 4,
          );

      step(0, inside: true);
      // 退出中は候補そのものが消える。
      for (var second = 1; second <= 10; second++) {
        step(second, inside: false);
      }
      // 再武装(5秒)を満たしてから再進入すると、1回目として鳴る。
      final reentry = step(11, inside: true);
      final candidate = reentry.snapshot.activeAlerts.single.candidate;
      expect(candidate.reasonCodes, contains('GUIDANCE_ENTRY'));
      expect(candidate.audioAsset, 'audio/curve_warning.mp3');
    });

    test('逆走の再武装は60秒、カーブは5秒のまま', () {
      String? audioAssetOf(SafetyOrchestratorResult result) =>
          result.snapshot.activeAlerts.single.candidate.audioAsset;

      SafetyOrchestratorResult run(
        SafetyOrchestrator orchestrator,
        StaticObstacleKind kind,
        int second, {
        required bool inside,
      }) =>
          orchestrator.processAssessment(
            assessment: assessment(inside ? [guidanceThreat(kind)] : const []),
            evaluatedAt: t0.add(Duration(seconds: second)),
            capabilities: capabilities,
            ownSpeedMetersPerSecond: 4,
          );

      final reverse = SafetyOrchestrator(
        sessionId: 'session-reverse-rearm',
        sessionGeneration: 1,
      );
      expect(
        audioAssetOf(run(reverse, StaticObstacleKind.reverse, 0, inside: true)),
        'audio/reverse_warning.mp3',
      );
      run(reverse, StaticObstacleKind.reverse, 1, inside: false);
      // 10秒で戻ってきても鳴らない(カーブの5秒なら鳴ってしまう)。
      expect(
        audioAssetOf(
          run(reverse, StaticObstacleKind.reverse, 11, inside: true),
        ),
        isNull,
      );
      run(reverse, StaticObstacleKind.reverse, 12, inside: false);
      expect(
        audioAssetOf(
          run(reverse, StaticObstacleKind.reverse, 73, inside: true),
        ),
        'audio/reverse_warning.mp3',
      );

      final curve = SafetyOrchestrator(
        sessionId: 'session-curve-rearm',
        sessionGeneration: 1,
      );
      expect(
        audioAssetOf(run(curve, StaticObstacleKind.curve, 0, inside: true)),
        'audio/curve_warning.mp3',
      );
      run(curve, StaticObstacleKind.curve, 1, inside: false);
      expect(
        audioAssetOf(run(curve, StaticObstacleKind.curve, 7, inside: true)),
        'audio/curve_warning.mp3',
      );
    });

    test('方向確認済みの逆走は表示を即時に出し、音声だけ6秒待つ', () {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-reverse-confirm',
        sessionGeneration: 1,
      );
      SafetyOrchestratorResult step(int second, {required bool inside}) =>
          orchestrator.processAssessment(
            assessment: assessment(
              inside
                  ? [
                      guidanceThreat(
                        StaticObstacleKind.reverse,
                        reverseDirectionConfirmed: true,
                      ),
                    ]
                  : const [],
            ),
            evaluatedAt: t0.add(Duration(seconds: second)),
            capabilities: capabilities,
            ownSpeedMetersPerSecond: 4,
          );

      for (var second = 0; second <= 5; second++) {
        final snapshot = step(second, inside: true).snapshot;
        // 候補・バナー用の状態は即時に残す。音だけを待たせる。
        expect(snapshot.activeAlerts, hasLength(1));
        final candidate = snapshot.activeAlerts.single.candidate;
        expect(candidate.reasonCodes, contains('REVERSE_CONFIRM_PENDING'));
        expect(candidate.audioAsset, isNull);
        expect(
            snapshot.audioDirective?.asset, isNot('audio/reverse_warning.mp3'));
      }

      final confirmed = step(6, inside: true).snapshot;
      final confirmedCandidate = confirmed.activeAlerts.single.candidate;
      expect(confirmedCandidate.audioAsset, 'audio/reverse_warning.mp3');
      expect(confirmedCandidate.reasonCodes,
          isNot(contains('REVERSE_CONFIRM_PENDING')));
      expect(confirmed.audioDirective?.asset, 'audio/reverse_warning.mp3');

      // 退出すると確認状態を即座に消す。再進入では60秒のrearmとは独立して
      // 再び6秒連続を要求する。
      step(7, inside: false);
      final reentered =
          step(8, inside: true).snapshot.activeAlerts.single.candidate;
      expect(reentered.reasonCodes, contains('REVERSE_CONFIRM_PENDING'));
      expect(reentered.audioAsset, isNull);
    });
  });

  group('低速時の音声静音', () {
    test('3秒後に橋脚だけを静音し、漕ぎ出した1測位で復帰する', () {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-low-speed-pier',
        sessionGeneration: 1,
      );
      SafetyOrchestratorResult step(int second, double speed) =>
          orchestrator.processAssessment(
            assessment: assessment([
              staticThreat(
                obstacleId: 'bridgepier_nioi_1',
                bridgeId: 'bridge_nioi',
                kind: StaticObstacleKind.bridgePier,
                distanceMeters: 1,
                entrySeconds: 3,
              ),
            ]),
            evaluatedAt: t0.add(Duration(seconds: second)),
            capabilities: capabilities,
            ownSpeedMetersPerSecond: speed,
          );

      expect(step(0, 1.0).snapshot.audioDirective, isNotNull);
      expect(step(2, 1.0).snapshot.audioDirective, isNotNull);
      final muted = step(3, 1.0).snapshot;
      expect(muted.activeAlerts, hasLength(1));
      expect(muted.activeAlerts.single.candidate.audioAsset, isNull);
      expect(muted.audioDirective, isNull);

      final resumed = step(4, 2.0).snapshot;
      expect(resumed.activeAlerts.single.candidate.audioAsset,
          'audio/bridge_pier_warning.mp3');
    });

    test('低速でも流木と他艇は静音にしない', () {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-low-speed-exceptions',
        sessionGeneration: 1,
      );
      SafetyOrchestratorResult step(int second) =>
          orchestrator.processAssessment(
            assessment: assessment([
              staticThreat(
                obstacleId: 'driftwood_1',
                kind: StaticObstacleKind.driftwood,
                distanceMeters: 1,
                entrySeconds: 3,
              ),
            ]),
            evaluatedAt: t0.add(Duration(seconds: second)),
            capabilities: capabilities,
            ownSpeedMetersPerSecond: 1.0,
          );
      step(0);
      step(1);
      step(2);
      final afterConfirmation = step(3).snapshot;
      expect(afterConfirmation.audioDirective?.asset,
          'audio/driftwood_warning.mp3');
    });
  });
}
