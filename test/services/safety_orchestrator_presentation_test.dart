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
    List<String> reasonCodes = const [],
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
            reasonCodes: reasonCodes,
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
          systemFault(
            detectorId: 'position_sharing',
            category: 'position_sharing_unavailable',
            at: t0,
          ),
        ],
        ownSpeedMetersPerSecond: 4,
      );

      expect(
        result.state.primaryAlert?.candidate.category,
        'position_sharing_unavailable',
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

    test('区域内にいる間は2回1組でカーブを読み上げ直す', () {
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

      // ここまでが1組(2回)。組を終えたら次の組まで静寂を置く。
      // 均等5秒で鳴らし続けると聞き手が慣れて無視するため、
      // 組にして体感のうるささを下げる(S3-08)。
      for (var second = 6; second <= 19; second++) {
        expect(
          step(second).audioEventId,
          firstRepeat.audioEventId,
          reason: '組の直後は静寂を置く($second 秒)',
        );
      }
      // 静寂(15秒)が明けたら次の組の1回目。
      final secondBurst = step(20);
      expect(secondBurst.audioEventId, isNot(firstRepeat.audioEventId));
      expect(secondBurst.reasonCodes, contains('GUIDANCE_REPEAT'));
      // 組の中は再び5秒間隔。
      expect(step(24).audioEventId, secondBurst.audioEventId);
      expect(step(25).audioEventId, isNot(secondBurst.audioEventId));
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

    test('抑制規則は下げるだけで、下げた結果を上書きしない', () {
      // 低速静音で visualOnly にした岸の警告が、安定停止の分岐で
      // singleAction へ「戻って」いた(`baseBehavior` を見て代入していた)。
      // 2026-08-05 の実機ログでは、これが桟橋で292サンプル鳴っていた
      // `PRESENTATION_STABLE_STOP_SINGLE` の正体である。
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-suppression-monotonic',
        sessionGeneration: 1,
      );
      SafetyOrchestratorResult step(int second) =>
          orchestrator.processAssessment(
            assessment: assessment([
              staticThreat(
                obstacleId: 'shore_north_24',
                sourceId: 'shore_north',
                overlap: true,
                distanceMeters: 4,
              ),
            ]),
            evaluatedAt: t0.add(Duration(seconds: second)),
            capabilities: capabilities,
            // 分速100m未満。橋の下・岸際で休憩している正常な運用。
            ownSpeedMetersPerSecond: 0.2,
          );

      // 3秒で低速静音が確定し、5秒で安定停止も確定する。
      // そのあとも音が戻らないこと。
      for (var second = 0; second <= 12; second++) {
        final snapshot = step(second).snapshot;
        if (second < 3) continue;
        expect(
          snapshot.audioDirective,
          isNull,
          reason: '$second秒目で音が戻っている',
        );
        expect(
          snapshot.activeAlerts.single.candidate.behavior,
          AlertBehavior.visualOnly,
        );
      }
    });

    test('係留中に速度が0.4m/sをまたいでも静音は巻き戻らない', () {
      // 係留中の艇は波と測位ノイズで 0.0〜0.6m/s を往復する。
      // 単一のしきい値だと安定停止に入っては抜けるを繰り返し、
      // そのたびに静音の確定待ちが巻き戻って単発音が漏れていた。
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-stop-hysteresis',
        sessionGeneration: 1,
      );
      const wobble = <double>[0.2, 0.5, 0.1, 0.6, 0.3, 0.55, 0.15];
      SafetyOrchestratorResult step(int second, double speed) =>
          orchestrator.processAssessment(
            assessment: assessment([
              // 重なりではなく「到達予測のある」脅威にする。重なりは
              // 「縮まっていなければ表示のみ」という別規則が先に効くため、
              // ここで見たい静音の巻き戻りが隠れてしまう。
              staticThreat(
                obstacleId: 'shore_north_24',
                sourceId: 'shore_north',
                distanceMeters: 4,
                entrySeconds: 3,
              ),
            ]),
            evaluatedAt: t0.add(Duration(seconds: second)),
            capabilities: capabilities,
            ownSpeedMetersPerSecond: speed,
          );

      for (var second = 0; second <= 20; second++) {
        final snapshot = step(second, wobble[second % wobble.length]).snapshot;
        if (second < 3) continue;
        expect(
          snapshot.audioDirective,
          isNull,
          reason: '$second秒目で音が漏れている',
        );
      }

      // 本当に漕ぎ出せば(0.8m/s以上)、従来どおり鳴る。
      expect(step(21, 2.0).snapshot.audioDirective, isNotNull);
    });

    test('不確かさでのみ重なる候補は低速時に表示だけへ落とす', () {
      // GPS帯を含めたときだけ重なる候補(`gps_guard_entry`)は、測位が疎に
      // なるほど現れやすくなる。停止中にこれで鳴らすと、測位品質の低下が
      // そのまま過剰警告に化ける(2026-08-05 実機ログ: 桟橋で31回)。
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-uncertainty-only',
        sessionGeneration: 1,
      );
      SafetyOrchestratorResult step(int second, double speed) =>
          orchestrator.processAssessment(
            assessment: assessment([
              staticThreat(
                obstacleId: 'shore_north_24',
                sourceId: 'shore_north',
                overlap: true,
                distanceMeters: 4,
                reasonCodes: const [
                  'continuous_domain_entry',
                  'gps_guard_entry',
                ],
              ),
            ]),
            evaluatedAt: t0.add(Duration(seconds: second)),
            capabilities: capabilities,
            ownSpeedMetersPerSecond: speed,
          );

      // 停止直後の1測位目から表示だけにする。3秒の確定待ちを持たないのは、
      // 有意接近のたびに巻き戻る確定待ちでは測位が疎な場面で成立しないため。
      final stopped = step(0, 0.2).snapshot;
      expect(stopped.activeAlerts, hasLength(1));
      expect(stopped.audioDirective, isNull);
      expect(
        stopped.activeAlerts.single.candidate.reasonCodes,
        contains('PRESENTATION_UNCERTAINTY_ONLY_VISUAL'),
      );

      // 漕ぎ出せば従来どおり鳴る。検知そのものは一切変えていない。
      final moving = step(1, 3.0).snapshot;
      expect(moving.audioDirective, isNotNull);
    });

    test('不確かさだけの他艇接近は、相手が動く又は速度不明なら音を維持する', () {
      // boatThreat の重なりに GPS 帯だけで入ったことを表す。
      // reason code は候補化後に付くため、専用の脅威を組み立てる。
      RiskAssessment uncertaintyBoatAssessment() => assessment([
            RiskThreat(
              level: CollisionRiskLevel.lv3,
              threat: ThreatInfo(
                kind: ThreatKind.boat,
                position: const LatLng(36.0, 140.0),
                boatId: 'other-uncertain',
                distanceMeters: 4,
                continuousIntersection: const ContinuousIntersection(
                  intersects: true,
                  currentOverlap: true,
                  firstEntryTimeSeconds: 0,
                  firstExitTimeSeconds: 2,
                  minimumSeparationMeters: 0,
                  reasonCodes: ['gps_guard_entry'],
                ),
              ),
            ),
          ]);

      SafetyOrchestratorResult uncertainRun(double? otherSpeed) {
        final orchestrator = SafetyOrchestrator(
          sessionId: 'session-uncertainty-other-${otherSpeed ?? 'unknown'}',
          sessionGeneration: 1,
        );
        return orchestrator.processAssessment(
          assessment: uncertaintyBoatAssessment(),
          evaluatedAt: t0,
          capabilities: capabilities,
          ownSpeedMetersPerSecond: 0.2,
          otherBoatSpeedById: {'other-uncertain': otherSpeed},
        );
      }

      expect(uncertainRun(2.0).snapshot.audioDirective, isNotNull);
      expect(uncertainRun(null).snapshot.audioDirective, isNotNull);

      final stopped = uncertainRun(0.1).snapshot;
      expect(stopped.audioDirective, isNull);
      expect(
        stopped.activeAlerts.single.candidate.reasonCodes,
        contains('PRESENTATION_UNCERTAINTY_ONLY_VISUAL'),
      );
    });

    test('区域案内は2回1組で鳴らし、組の間隔を伸ばす(S3-08)', () {
      // 逆走は「入った」という一度きりの事実ではなく、是正されるまで
      // 続く状態である。実機ログの逆走警告は誤検知ではなく実際に
      // 逆走していた。回数で打ち切ると、状態が続いているのに黙る。
      //
      // うるささは頻度で解く。2回鳴らして静寂、が1組。
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-guidance-burst',
        sessionGeneration: 1,
      );
      final firedAt = <int>[];
      String? previous;
      for (var second = 0; second <= 300; second += 1) {
        final result = orchestrator.processAssessment(
          assessment: assessment([
            guidanceThreat(StaticObstacleKind.curve),
          ]),
          evaluatedAt: t0.add(Duration(seconds: second)),
          capabilities: capabilities,
          ownSpeedMetersPerSecond: 3,
        );
        final eventId = result.snapshot.audioDirective?.eventId;
        if (eventId != null && eventId != previous) {
          previous = eventId;
          firedAt.add(second);
        }
      }

      // 5分居続けても鳴り止まない。打ち切らないことが要件である。
      expect(firedAt.length, greaterThan(6));

      // 組の1回目と2回目は短い間隔(5秒)で続く。
      expect(firedAt[1] - firedAt[0], 5);
      expect(firedAt[3] - firedAt[2], 5);

      // 組と組のあいだは空く。しかも回を追うごとに広がる。
      final firstIdle = firedAt[2] - firedAt[1];
      final secondIdle = firedAt[4] - firedAt[3];
      expect(firstIdle, greaterThan(5));
      expect(secondIdle, greaterThan(firstIdle));

      // 上限で頭打ちになり、間延びし続けない。
      final gaps = <int>[
        for (var i = 1; i < firedAt.length; i++) firedAt[i] - firedAt[i - 1],
      ];
      expect(gaps.reduce((a, b) => a > b ? a : b), lessThanOrEqualTo(60));

      // 均等5秒なら61回。組にすることで大きく減る。
      expect(firedAt.length, lessThan(20));
    });

    test('他艇のGPS帯だけの重なりは、バンドを1段下げない(S3-06)', () {
      // 艇間の相対誤差は共通誤差が相殺してほぼ0であり(2026-08-06 実機:
      // 真値1.5〜2mに対しraw位置差 中央値1.7m)、不確かさは
      // ProtectionBudget の相対合成で領域として表現済みである。
      // ここで重ねてバンドを下げると二重に保守的になる。
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-boat-guard-no-demotion',
        sessionGeneration: 1,
      );
      final result = orchestrator.processAssessment(
        assessment: assessment([
          RiskThreat(
            level: CollisionRiskLevel.lv3,
            threat: ThreatInfo(
              kind: ThreatKind.boat,
              position: const LatLng(36.0, 140.0),
              boatId: 'other-guard',
              distanceMeters: 4,
              // GPS帯込みでのみ重なった候補。実機の評価器はここを
              // uncertain にし、候補の confidence が 0.7 になる。
              confidence: ThreatConfidence.uncertain,
              continuousIntersection: const ContinuousIntersection(
                intersects: true,
                currentOverlap: true,
                firstEntryTimeSeconds: 0,
                firstExitTimeSeconds: 2,
                minimumSeparationMeters: 0,
                reasonCodes: ['gps_guard_entry'],
              ),
            ),
          ),
        ]),
        evaluatedAt: t0,
        capabilities: capabilities,
        // 自艇は航行中。低速静音の分岐へは入らない。
        ownSpeedMetersPerSecond: 3,
        otherBoatSpeedById: const {'other-guard': 2.0},
      );
      final candidate = result.snapshot.activeAlerts.single.candidate;
      // 降格が効いていないことの確認。confidence は 0.7 のままである。
      expect(candidate.confidence, lessThan(1.0));
      expect(candidate.behavior, AlertBehavior.continuousAction);
    });

    test('静的区域のGPS帯だけの重なりは、従来どおり1段下げる(S3-06)', () {
      // 危険区域は絶対座標に固定なので、自艇のGNSS誤差ぶんだけ広げた帯で
      // 「だけ」重なる候補は本当に確度が低い。降格は維持する。
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-static-guard-demotion',
        sessionGeneration: 1,
      );
      final result = orchestrator.processAssessment(
        assessment: assessment([
          RiskThreat(
            level: CollisionRiskLevel.lv2,
            threat: ThreatInfo(
              kind: ThreatKind.obstacle,
              position: const LatLng(36.0, 140.0),
              obstacleKind: StaticObstacleKind.driftwood,
              obstacleId: 'driftwood-guard',
              distanceMeters: 4,
              confidence: ThreatConfidence.uncertain,
              continuousIntersection: const ContinuousIntersection(
                intersects: true,
                currentOverlap: true,
                firstEntryTimeSeconds: 0,
                firstExitTimeSeconds: 2,
                minimumSeparationMeters: 0,
                reasonCodes: ['gps_guard_entry'],
              ),
            ),
          ),
        ]),
        evaluatedAt: t0,
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 3,
      );
      final candidate = result.snapshot.activeAlerts.single.candidate;
      expect(candidate.confidence, lessThan(1.0));
      expect(candidate.behavior, isNot(AlertBehavior.continuousAction));
    });

    test('確度の高い他艇接近は低速でも従来どおり鳴る', () {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-definite-other-at-rest',
        sessionGeneration: 1,
      );
      final result = orchestrator.processAssessment(
        assessment: assessment([boatThreat(boatId: 'other-definite')]),
        evaluatedAt: t0,
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 0.2,
        otherBoatSpeedById: const {'other-definite': 2.0},
      );
      expect(result.snapshot.audioDirective, isNotNull);
    });

    test('確度の高い候補は低速でも従来どおり鳴る', () {
      // 不確かさによる抑制が、実体の重なりまで巻き込まないことを固定する。
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-definite-at-rest',
        sessionGeneration: 1,
      );
      final result = orchestrator.processAssessment(
        assessment: assessment([
          staticThreat(
            obstacleId: 'driftwood_1',
            kind: StaticObstacleKind.driftwood,
            overlap: true,
            distanceMeters: 1,
            reasonCodes: const ['continuous_domain_entry'],
          ),
        ]),
        evaluatedAt: t0,
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 0.2,
      );
      expect(
          result.snapshot.audioDirective?.asset, 'audio/driftwood_warning.mp3');
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

  // ---- 5. 測位欠測による音声エピソードの再武装 ----

  group('測位欠測と音声エピソード', () {
    test('数秒消えて戻った同じ脅威は単発音を鳴らし直さない', () {
      // GPSが数秒途絶えると候補が消える。復帰した瞬間に「新しい脅威」として
      // 単発音が鳴り直していた(2026-08-05 実機ログ: 桟橋で8秒周期に同期)。
      // 測位の欠測は脅威が消えた証拠ではない(原則6)。
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-gap-rearm',
        sessionGeneration: 1,
      );
      SafetyOrchestratorResult step(int second, {required bool present}) =>
          orchestrator.processAssessment(
            assessment: assessment([
              if (present)
                staticThreat(
                  obstacleId: 'driftwood_1',
                  kind: StaticObstacleKind.driftwood,
                  distanceMeters: 2,
                  entrySeconds: 3,
                ),
            ]),
            evaluatedAt: t0.add(Duration(seconds: second)),
            capabilities: capabilities,
            ownSpeedMetersPerSecond: 3.0,
          );

      final first = step(0, present: true).snapshot;
      final firstEventId = first.audioDirective?.eventId;
      expect(firstEventId, isNotNull);

      // 3秒の欠測。候補が消えるが、音声エピソードは据え置く。
      step(1, present: false);
      step(2, present: false);
      step(3, present: false);

      final resumed = step(4, present: true).snapshot;
      expect(resumed.audioDirective, isNotNull);
      expect(
        resumed.audioDirective!.eventId,
        firstEventId,
        reason: 'eventIdが同じなら use_alert の重複排除で鳴り直さない',
      );
    });

    test('保持時間を超えて消えた脅威は新しいエピソードとして鳴らし直す', () {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-gap-expired',
        sessionGeneration: 1,
      );
      SafetyOrchestratorResult step(int second, {required bool present}) =>
          orchestrator.processAssessment(
            assessment: assessment([
              if (present)
                staticThreat(
                  obstacleId: 'driftwood_1',
                  kind: StaticObstacleKind.driftwood,
                  distanceMeters: 2,
                  entrySeconds: 3,
                ),
            ]),
            evaluatedAt: t0.add(Duration(seconds: second)),
            capabilities: capabilities,
            ownSpeedMetersPerSecond: 3.0,
          );

      final first = step(0, present: true).snapshot;
      final firstEventId = first.audioDirective?.eventId;
      expect(firstEventId, isNotNull);

      // 既定の保持時間は5秒。それを超えたら本当に離れたと扱う。
      for (var second = 1; second <= 8; second++) {
        step(second, present: false);
      }
      final resumed = step(9, present: true).snapshot;
      expect(resumed.audioDirective, isNotNull);
      expect(resumed.audioDirective!.eventId, isNot(firstEventId));
    });
  });

  // ---- 6. 桟橋エリア ----

  group('桟橋エリア', () {
    // 桟橋を囲む小さな四角形。実座標はプロットツールで入れる。
    const dock = <LatLng>[
      LatLng(36.0830, 140.2140),
      LatLng(36.0830, 140.2150),
      LatLng(36.0836, 140.2150),
      LatLng(36.0836, 140.2140),
    ];
    const insideDock = LatLng(36.0833, 140.2145);
    const outsideDock = LatLng(36.0900, 140.2145);

    SafetyOrchestratorResult run({
      required List<List<LatLng>> areas,
      required LatLng? ownPosition,
      required double ownSpeed,
      required double? otherSpeed,
    }) {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-mooring',
        sessionGeneration: 1,
        mooringAreas: areas,
      );
      return orchestrator.processAssessment(
        assessment: assessment([boatThreat(boatId: 'other-1')]),
        evaluatedAt: t0,
        capabilities: capabilities,
        ownSpeedMetersPerSecond: ownSpeed,
        ownPosition: ownPosition,
        otherBoatSpeedById: {'other-1': otherSpeed},
        healthyBoatIds: const {'other-1'},
      );
    }

    test('区域内で双方が低速なら他艇の連続音を止め、表示は残す', () {
      final result = run(
        areas: const [dock],
        ownPosition: insideDock,
        ownSpeed: 0.2,
        otherSpeed: 0.2,
      );
      expect(result.snapshot.audioDirective, isNull);
      final candidate = result.snapshot.activeAlerts.single.candidate;
      expect(candidate.category, 'other_boat');
      // 表示・内部レベル・記録は一切変えない。
      expect(candidate.internalPriority, CollisionRiskLevel.lv3.index);
      expect(
          candidate.reasonCodes, contains('PRESENTATION_MOORING_AREA_SILENT'));
      expect(result.state.activeAlerts, hasLength(1));
    });

    test('相手が動いていれば区域内でも従来どおり鳴る', () {
      final result = run(
        areas: const [dock],
        ownPosition: insideDock,
        ownSpeed: 0.2,
        otherSpeed: 2.0,
      );
      expect(result.snapshot.audioDirective?.asset,
          'audio/other_boat_warning.mp3');
    });

    test('自艇が動いていれば区域内でも従来どおり鳴る', () {
      final result = run(
        areas: const [dock],
        ownPosition: insideDock,
        ownSpeed: 3.0,
        otherSpeed: 0.2,
      );
      expect(result.snapshot.audioDirective?.asset,
          'audio/other_boat_warning.mp3');
    });

    test('相手の速度が取れないときは抑制しない(原則6)', () {
      final result = run(
        areas: const [dock],
        ownPosition: insideDock,
        ownSpeed: 0.2,
        otherSpeed: null,
      );
      expect(result.snapshot.audioDirective?.asset,
          'audio/other_boat_warning.mp3');
    });

    test('区域外では一切影響しない', () {
      final result = run(
        areas: const [dock],
        ownPosition: outsideDock,
        ownSpeed: 0.2,
        otherSpeed: 0.2,
      );
      expect(result.snapshot.audioDirective?.asset,
          'audio/other_boat_warning.mp3');
    });

    test('区域内で低速なら岸の警告も止め、表示は残す', () {
      // 桟橋は定義上いつも岸の隣にあり、艇は必ず岸へ寄せて止める。
      // そこで岸の警告を鳴らすのは原則4に正面から当たる。
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-mooring-shore',
        sessionGeneration: 1,
        mooringAreas: const [dock],
      );
      final result = orchestrator.processAssessment(
        assessment: assessment([
          staticThreat(
            obstacleId: 'shore_north_24',
            sourceId: 'shore_north',
            overlap: true,
            distanceMeters: 4,
          ),
        ]),
        evaluatedAt: t0,
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 0.2,
        ownPosition: insideDock,
      );
      // 3秒の確定待ちを挟まず、最初の1測位から止める。
      expect(result.snapshot.audioDirective, isNull);
      final candidate = result.snapshot.activeAlerts.single.candidate;
      expect(
          candidate.reasonCodes, contains('PRESENTATION_MOORING_AREA_SILENT'));
      expect(result.state.activeAlerts, hasLength(1));
    });

    test('区域内でも漕いでいれば岸の警告は従来どおり鳴る', () {
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-mooring-shore-moving',
        sessionGeneration: 1,
        mooringAreas: const [dock],
      );
      final result = orchestrator.processAssessment(
        assessment: assessment([
          staticThreat(
            obstacleId: 'shore_north_24',
            sourceId: 'shore_north',
            distanceMeters: 4,
            entrySeconds: 3,
          ),
        ]),
        evaluatedAt: t0,
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 3.0,
        ownPosition: insideDock,
      );
      expect(result.snapshot.audioDirective?.asset, 'audio/shore_warning.mp3');
    });

    test('区域内でも流木・杭は止めない(視認しづらく帰結が大きい)', () {
      // `lowSpeedMutedCategories` に入っていない種類は桟橋でも鳴らす。
      final orchestrator = SafetyOrchestrator(
        sessionId: 'session-mooring-driftwood',
        sessionGeneration: 1,
        mooringAreas: const [dock],
      );
      final result = orchestrator.processAssessment(
        assessment: assessment([
          staticThreat(
            obstacleId: 'driftwood_1',
            kind: StaticObstacleKind.driftwood,
            overlap: true,
            distanceMeters: 1,
          ),
        ]),
        evaluatedAt: t0,
        capabilities: capabilities,
        ownSpeedMetersPerSecond: 0.2,
        ownPosition: insideDock,
      );
      expect(
        result.snapshot.audioDirective?.asset,
        'audio/driftwood_warning.mp3',
      );
    });

    test('桟橋エリアが無いプロファイルでも従来どおり鳴る', () {
      final result = run(
        areas: const [],
        ownPosition: insideDock,
        ownSpeed: 0.2,
        otherSpeed: 0.2,
      );
      expect(result.snapshot.audioDirective?.asset,
          'audio/other_boat_warning.mp3');
    });

    test('自艇の座標が取れないときは抑制しない(原則6)', () {
      final result = run(
        areas: const [dock],
        ownPosition: null,
        ownSpeed: 0.2,
        otherSpeed: 0.2,
      );
      expect(result.snapshot.audioDirective?.asset,
          'audio/other_boat_warning.mp3');
    });
  });
}
