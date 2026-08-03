import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/models/alert_candidate.dart';
import 'package:rowing_navigator/models/navigation_warning.dart';
import 'package:rowing_navigator/models/static_obstacle_model.dart';
import 'package:rowing_navigator/services/collision_risk_evaluator_service.dart';
import 'package:rowing_navigator/services/navigation_warning_service.dart';
import 'package:rowing_navigator/types/collision_risk_level.dart';

void main() {
  final service = NavigationWarningService();

  test('安全な評価では警告を表示・再生しない', () {
    expect(
      service.fromAssessment(
        RiskAssessment(level: CollisionRiskLevel.lv0),
      ),
      isNull,
    );
  });

  test('リスクレベルに関係なく橋には橋の音声を割り当てる', () {
    for (final level in [
      CollisionRiskLevel.lv1,
      CollisionRiskLevel.lv2,
      CollisionRiskLevel.lv3,
    ]) {
      final warning = service.fromAssessment(RiskAssessment(
        level: level,
        primaryThreat: ThreatInfo(
          kind: ThreatKind.obstacle,
          position: const LatLng(36, 140),
          obstacleKind: StaticObstacleKind.bridge,
          obstacleId: 'bridge_sakuragawa',
          obstacleName: '桜川橋',
        ),
      ));

      expect(warning?.key, 'obstacle:bridge_sakuragawa');
      expect(warning?.title, '桜川橋に接近');
      expect(warning?.audioAsset, 'audio/bridge_warning.mp3');
    }
  });

  test('区域ごとのwarningAudioで標準音声を上書きできる', () {
    final warning = service.fromAssessment(RiskAssessment(
      level: CollisionRiskLevel.lv1,
      primaryThreat: ThreatInfo(
        kind: ThreatKind.obstacle,
        position: const LatLng(36, 140),
        obstacleKind: StaticObstacleKind.shore,
        obstacleId: 'north_shore',
        warningAudioAsset: 'audio/custom_north_shore.mp3',
      ),
    ));

    expect(warning?.audioAsset, 'audio/custom_north_shore.mp3');
  });

  test('他艇は艇IDで警告状態を識別する', () {
    final warning = service.fromAssessment(RiskAssessment(
      level: CollisionRiskLevel.lv2,
      primaryThreat: ThreatInfo(
        kind: ThreatKind.boat,
        position: const LatLng(36, 140),
        boatId: 'boat-2',
      ),
    ));

    expect(warning?.key, 'boat:boat-2');
    expect(warning?.audioAsset, 'audio/other_boat_warning.mp3');
  });

  test('推測警告は残り秒数を持ち、岸表示は省スペースにする', () {
    final warning = service.fromCandidate(AlertCandidate.stable(
      detectorId: 'static_collision',
      category: 'shore',
      targetId: 'shore-a',
      behavior: AlertBehavior.continuousAction,
      evaluatedAt: DateTime.utc(2026, 7, 15),
      observationId: 'shore-1',
      actionDeadline: const Duration(milliseconds: 6200),
      currentOverlap: false,
    ));

    expect(warning?.title, '岸に接近');
    expect(warning?.message, isEmpty);
    expect(warning?.isPredicted, isTrue);
    expect(warning?.secondsUntilDanger, 7);
  });

  test('カーブと逆走注意は進入イベントとして一回音声にする', () {
    NavigationWarning warning(String category) => service.fromCandidate(
          AlertCandidate.stable(
            detectorId: 'guidance_zone_entry',
            category: category,
            targetId: category,
            behavior: AlertBehavior.entryEvent,
            evaluatedAt: DateTime.utc(2026, 7, 15),
            observationId: category,
            currentOverlap: true,
            audioEventId: 'entry:$category:1',
          ),
        )!;

    expect(warning('curve').audioMode, WarningAudioMode.once);
    expect(warning('reverse').audioMode, WarningAudioMode.once);
    expect(warning('reverse').audioEventId, 'entry:reverse:1');
    expect(warning('curve').title, 'カーブ注意');
    expect(warning('reverse').title, '逆走注意');
  });

  test('行動警告は単発、表示だけの注意は無音として変換する', () {
    AlertCandidate candidate(AlertBehavior behavior, {String? audioAsset}) =>
        AlertCandidate.stable(
          detectorId: 'static_collision',
          category: 'shore',
          targetId: 'shore-a',
          behavior: behavior,
          evaluatedAt: DateTime.utc(2026, 7, 15),
          observationId: behavior.name,
          audioAsset: audioAsset,
          audioEventId: 'risk-1',
        );

    final action = service.fromCandidate(candidate(
      AlertBehavior.singleAction,
      audioAsset: 'audio/shore_warning.mp3',
    ));
    final caution = service.fromCandidate(
      candidate(AlertBehavior.visualOnly),
    );

    expect(action?.audioMode, WarningAudioMode.once);
    expect(action?.audioEventId, 'risk-1');
    expect(caution?.audioAsset, isNull);
  });
}
