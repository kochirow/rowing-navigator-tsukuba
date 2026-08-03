import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/config/risk_evaluator_config.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import 'package:rowing_navigator/models/channel_lane.dart';
import 'package:rowing_navigator/models/static_obstacle_model.dart';
import 'package:rowing_navigator/services/channel_centerline.dart';
import 'package:rowing_navigator/services/channel_lane_resolver.dart';
import 'package:rowing_navigator/services/collision_risk_evaluator_service.dart';
import 'package:rowing_navigator/services/preset_obstacle_service.dart';
import 'package:rowing_navigator/types/boat_type.dart';
import 'package:rowing_navigator/types/collision_risk_level.dart';

const originLatitude = 36.08;
const originLongitude = 140.12;
const metersPerLatitudeDegree = 111195.08;

LatLng at({required double east, required double north}) => LatLng(
      originLatitude + north / metersPerLatitudeDegree,
      originLongitude +
          east /
              (metersPerLatitudeDegree *
                  math.cos(originLatitude * math.pi / 180)),
    );

/// 真北へ真っ直ぐ伸びる航路中心線。接線方位 T = 0度。
/// 右側通行なので、T の右手側(= 東側 / cross > 0)にいる艇は北向きに、
/// 左手側(= 西側 / cross < 0)にいる艇は南向きに進むのが規定である。
ChannelCenterline straightCenterline({double lengthMeters = 600}) =>
    ChannelCenterline.fromPolyline([
      for (var north = 0.0; north <= lengthMeters; north += 50)
        at(east: 0, north: north),
    ])!;

StaticObstacle zone(
  StaticObstacleKind kind, {
  required double southNorth,
  required double northNorth,
  String? id,
}) =>
    StaticObstacle(
      id: id ?? kind.name,
      sourceId: id ?? kind.name,
      name: kind.displayLabel,
      kind: kind,
      points: [
        at(east: -40, north: southNorth),
        at(east: 40, north: southNorth),
        at(east: 40, north: northNorth),
        at(east: -40, north: northNorth),
      ],
    );

Boat boatAt({
  required double east,
  required double north,
  required double heading,
  double speed = 4,
}) {
  final position = at(east: east, north: north);
  return Boat(
    boatId: 'own',
    boatType: BoatType.r_1x,
    lat: position.latitude,
    lng: position.longitude,
    heading: heading,
    speed: speed,
    timestamp: DateTime.now(),
    accuracy: 5,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final evaluator = CollisionRiskEvaluatorService();

  /// 逆走注意の脅威(あれば)を返す。
  RiskThreat? reverseThreat(
    Boat boat,
    List<StaticObstacle> obstacles, {
    ChannelCenterline? centerline,
    ChannelLaneResolver? laneResolver,
  }) {
    final assessment = evaluator.assessRisk(
      boat,
      const [],
      obstacles,
      warningTimeSeconds: defaultWarningTimeSeconds,
      centerline: centerline,
      laneResolver: laneResolver,
    );
    for (final threat in assessment.threats) {
      if (threat.threat.obstacleKind == StaticObstacleKind.reverse) {
        return threat;
      }
    }
    return null;
  }

  group('逆走注意の方向つき判定', () {
    final centerline = straightCenterline();
    // 中心線(0〜600m)の内側に収まる逆走注意区域。
    final reverseZone =
        zone(StaticObstacleKind.reverse, southNorth: 100, northNorth: 500);
    ChannelLane lane(
            String id, LaneDirection direction, double west, double east,
            [String? centerlineId]) =>
        ChannelLane(
          id: id,
          name: id,
          direction: direction,
          centerlineId: centerlineId,
          points: [
            at(east: west, north: 100),
            at(east: east, north: 100),
            at(east: east, north: 500),
            at(east: west, north: 500),
          ],
        );
    final completeLanes = ChannelLaneResolver([
      lane('lane_along', LaneDirection.along, 5, 25),
      lane('lane_against', LaneDirection.against, -25, -5),
    ]);

    test('水域ごとに紐付いた中心線を選び、別水域の向きを流用しない', () {
      final kasumigauraCenterline = ChannelCenterline.fromPolyline([
        at(east: 100, north: 600),
        at(east: 100, north: 0),
      ])!;
      final linkedResolver = ChannelLaneResolver(
        [
          lane(
            'sakuragawa_outbound',
            LaneDirection.along,
            5,
            25,
            'sakuragawa_axis',
          ),
          lane(
            'kasumigaura_outbound',
            LaneDirection.along,
            80,
            120,
            'kasumigaura_axis',
          ),
        ],
        centerlines: {
          'sakuragawa_axis': centerline,
          'kasumigaura_axis': kasumigauraCenterline,
        },
      );

      // 桜川中心線は北向きなので、北向きが規定。
      expect(
        evaluator.evaluateReverseGuidance(
          boatAt(east: 10, north: 300, heading: 0),
          null,
          laneResolver: linkedResolver,
        ),
        ReverseGuidanceOutcome.compliant,
      );
      // 霞ヶ浦中心線は南向きに引いたので、同じalongでも南向きが規定。
      expect(
        evaluator.evaluateReverseGuidance(
          boatAt(east: 100, north: 300, heading: 180),
          null,
          laneResolver: linkedResolver,
        ),
        ReverseGuidanceOutcome.compliant,
      );
      expect(
        evaluator.evaluateReverseGuidance(
          boatAt(east: 100, north: 300, heading: 0),
          null,
          laneResolver: linkedResolver,
        ),
        ReverseGuidanceOutcome.reverse,
      );

      // 旧ポリゴンが無くても、レーン全域で確認済み逆走を候補化する。
      final withoutLegacyZone = evaluator.assessRisk(
        boatAt(east: 100, north: 300, heading: 0),
        const [],
        const [],
        centerline: null,
        laneResolver: linkedResolver,
      );
      final linkedReverseThreats = withoutLegacyZone.threats
          .where((threat) =>
              threat.threat.obstacleKind == StaticObstacleKind.reverse)
          .toList();
      expect(linkedReverseThreats, hasLength(1));
      expect(
        linkedReverseThreats.single.threat.continuousIntersection?.reasonCodes,
        contains('linked_centerline_guidance'),
      );

      // 旧逆走注意エリアがデータに残っていても、二重候補にはしない。
      final withLegacyZone = evaluator.assessRisk(
        boatAt(east: 10, north: 300, heading: 180),
        const [],
        [reverseZone],
        centerline: null,
        laneResolver: linkedResolver,
      );
      expect(
        withLegacyZone.threats.where((threat) =>
            threat.threat.obstacleKind == StaticObstacleKind.reverse),
        hasLength(1),
      );

      // 規定方向なら、旧区域内にいても警告しない。
      expect(
        reverseThreat(
          boatAt(east: 10, north: 300, heading: 0),
          [reverseZone],
          laneResolver: linkedResolver,
        ),
        isNull,
      );
    });

    test('桜川河口と上流の間の移動水域で判定を中断し、上流で再開する', () {
      final mouthCenterline = ChannelCenterline.fromPolyline([
        at(east: 0, north: 0),
        at(east: 0, north: 220),
      ])!;
      final upstreamCenterline = ChannelCenterline.fromPolyline([
        at(east: 0, north: 300),
        at(east: 0, north: 600),
      ])!;

      ChannelLane segmentLane({
        required String id,
        required LaneDirection direction,
        required String centerlineId,
        required double west,
        required double east,
        required double south,
        required double north,
      }) =>
          ChannelLane(
            id: id,
            name: id,
            direction: direction,
            centerlineId: centerlineId,
            points: [
              at(east: west, north: south),
              at(east: east, north: south),
              at(east: east, north: north),
              at(east: west, north: north),
            ],
          );

      final segmentedResolver = ChannelLaneResolver(
        [
          segmentLane(
            id: 'sakuragawa_mouth_outbound',
            direction: LaneDirection.along,
            centerlineId: 'sakuragawa_mouth_axis',
            west: 5,
            east: 25,
            south: 50,
            north: 200,
          ),
          segmentLane(
            id: 'sakuragawa_mouth_return',
            direction: LaneDirection.against,
            centerlineId: 'sakuragawa_mouth_axis',
            west: -25,
            east: -5,
            south: 50,
            north: 200,
          ),
          segmentLane(
            id: 'sakuragawa_upstream_outbound',
            direction: LaneDirection.along,
            centerlineId: 'sakuragawa_upstream_axis',
            west: 5,
            east: 25,
            south: 350,
            north: 550,
          ),
          segmentLane(
            id: 'sakuragawa_upstream_return',
            direction: LaneDirection.against,
            centerlineId: 'sakuragawa_upstream_axis',
            west: -25,
            east: -5,
            south: 350,
            north: 550,
          ),
        ],
        centerlines: {
          'sakuragawa_mouth_axis': mouthCenterline,
          'sakuragawa_upstream_axis': upstreamCenterline,
        },
      );

      expect(segmentedResolver.hasLinkedCenterlines, isTrue);
      expect(
        reverseThreat(
          boatAt(east: 10, north: 100, heading: 180),
          const [],
          laneResolver: segmentedResolver,
        ),
        isNotNull,
        reason: '河口往路内では逆走を判定する',
      );
      expect(
        reverseThreat(
          boatAt(east: 10, north: 260, heading: 180),
          const [],
          laneResolver: segmentedResolver,
        ),
        isNull,
        reason: '移動水域はどのレーンにも属さないため逆走判定を中断する',
      );
      expect(segmentedResolver.centerlineFor(at(east: 10, north: 260)), isNull);
      expect(
        reverseThreat(
          boatAt(east: 10, north: 400, heading: 180),
          const [],
          laneResolver: segmentedResolver,
        ),
        isNotNull,
        reason: '上流往路へ入ると逆走判定を再開する',
      );
      expect(
        reverseThreat(
          boatAt(east: 10, north: 400, heading: 0),
          const [],
          laneResolver: segmentedResolver,
        ),
        isNull,
        reason: '上流往路を規定方向に進む場合は警告しない',
      );
    });

    test('右側通行どおりに漕いでいる艇は逆走にならない', () {
      // 東側(cross > 0)は北向きが規定。
      expect(
        evaluator.evaluateReverseGuidance(
          boatAt(east: 10, north: 300, heading: 0),
          centerline,
        ),
        ReverseGuidanceOutcome.compliant,
      );
      // 西側(cross < 0)は南向きが規定。
      expect(
        evaluator.evaluateReverseGuidance(
          boatAt(east: -10, north: 300, heading: 180),
          centerline,
        ),
        ReverseGuidanceOutcome.compliant,
      );
      // 区域内にいても発報しない。これが77分16回の過剰警告を消す本体。
      expect(
        reverseThreat(
          boatAt(east: 10, north: 300, heading: 0),
          [reverseZone],
          centerline: centerline,
        ),
        isNull,
      );
    });

    test('逆向きに漕いでいる艇は逆走になる', () {
      expect(
        evaluator.evaluateReverseGuidance(
          boatAt(east: 10, north: 300, heading: 180),
          centerline,
        ),
        ReverseGuidanceOutcome.reverse,
      );
      expect(
        evaluator.evaluateReverseGuidance(
          boatAt(east: -10, north: 300, heading: 0),
          centerline,
        ),
        ReverseGuidanceOutcome.reverse,
      );

      final threat = reverseThreat(
        boatAt(east: 10, north: 300, heading: 180),
        [reverseZone],
        centerline: centerline,
      );
      expect(threat, isNotNull);
      expect(threat!.level, CollisionRiskLevel.lv1);
      expect(
        threat.threat.continuousIntersection?.reasonCodes,
        contains('reverse_direction_confirmed'),
      );
      // 区域進入イベントとしての従来の扱い(即時扱い・残り秒数なし)を保つ。
      expect(threat.threat.continuousIntersection?.currentOverlap, isTrue);
      expect(
          threat.threat.continuousIntersection?.firstEntryTimeSeconds, isNull);
    });

    test('川を直角に横切る艇は逆走にならない', () {
      for (final heading in [90.0, 270.0]) {
        expect(
          evaluator.evaluateReverseGuidance(
            boatAt(east: 10, north: 300, heading: heading),
            centerline,
          ),
          ReverseGuidanceOutcome.compliant,
          reason: '横断(90度)は逆走ではない。heading=$heading',
        );
      }
      // しきい値の手前(119度)までは逆走にしない。
      expect(
        evaluator.evaluateReverseGuidance(
          boatAt(east: 10, north: 300, heading: 119),
          centerline,
        ),
        ReverseGuidanceOutcome.compliant,
      );
      expect(
        evaluator.evaluateReverseGuidance(
          boatAt(east: 10, north: 300, heading: 121),
          centerline,
        ),
        ReverseGuidanceOutcome.reverse,
      );
      expect(reverseGuidanceHeadingErrorDegrees, 120.0);
    });

    test('中心線の直上はレーンを決められないので逆走にしない', () {
      // GPS誤差で cross の符号が反転すると規定方位が180度ひっくり返る。
      // 正常な艇を逆走と誤判定しないためのガード。
      expect(
        evaluator.evaluateReverseGuidance(
          boatAt(east: 2, north: 300, heading: 180),
          centerline,
        ),
        ReverseGuidanceOutcome.compliant,
      );
      expect(reverseGuidanceLaneAmbiguityMeters, 5.0);
      // 帯の外(レーン中央側)では従来どおり判定する。
      expect(
        evaluator.evaluateReverseGuidance(
          boatAt(east: 6, north: 300, heading: 180),
          centerline,
        ),
        ReverseGuidanceOutcome.reverse,
      );
    });

    test('明示レーンの内包をcross符号より優先する', () {
      // 東側は従来のcross符号なら北向きが規定だが、レーン属性を against
      // としている。ここではレーンの明示情報を採るため北向きは逆走になる。
      final reversedDirectionLanes = ChannelLaneResolver([
        lane('lane_east_against', LaneDirection.against, 5, 25),
        lane('lane_west_along', LaneDirection.along, -25, -5),
      ]);
      expect(
        evaluator.evaluateReverseGuidance(
          boatAt(east: 10, north: 300, heading: 0),
          centerline,
          laneResolver: reversedDirectionLanes,
        ),
        ReverseGuidanceOutcome.reverse,
      );
      expect(
        evaluator.evaluateReverseGuidance(
          boatAt(east: 10, north: 300, heading: 180),
          centerline,
          laneResolver: reversedDirectionLanes,
        ),
        ReverseGuidanceOutcome.compliant,
      );
    });

    test('レーン間の隙間はlaneUndeterminedとなり区域内発報へ縮退しない', () {
      final boat = boatAt(east: 0, north: 300, heading: 180);
      expect(
        evaluator.evaluateReverseGuidance(
          boat,
          centerline,
          laneResolver: completeLanes,
        ),
        ReverseGuidanceOutcome.laneUndetermined,
      );
      expect(
        reverseThreat(
          boat,
          [reverseZone],
          centerline: centerline,
          laneResolver: completeLanes,
        ),
        isNull,
      );
    });

    test('レーンが1枚だけなら既存のcross符号方式へ縮退する', () {
      final incomplete = ChannelLaneResolver([
        lane('lane_only', LaneDirection.along, 5, 25),
      ]);
      expect(incomplete.hasCompleteLaneSet, isFalse);
      expect(
        evaluator.evaluateReverseGuidance(
          boatAt(east: 10, north: 300, heading: 180),
          centerline,
          laneResolver: incomplete,
        ),
        ReverseGuidanceOutcome.reverse,
      );
    });

    test('中心線が無ければ、従来どおり区域内で発報する(縮退運転)', () {
      expect(
        evaluator.evaluateReverseGuidance(
          boatAt(east: 10, north: 300, heading: 0),
          null,
        ),
        ReverseGuidanceOutcome.unverified,
      );
      final threat = reverseThreat(
        // 規定どおりの向きでも、方向を確かめられないなら黙らせない。
        boatAt(east: 10, north: 300, heading: 0),
        [reverseZone],
      );
      expect(threat, isNotNull, reason: '原則1: 縮退しても機能を止めない');
      expect(
        threat!.threat.continuousIntersection?.reasonCodes,
        contains('reverse_direction_unverified'),
      );
    });

    test('中心線のカバー範囲外でも、従来どおり区域内で発報する(縮退運転)', () {
      // 中心線は0〜300mまで。区域は100〜500mなので、上流側は範囲外になる。
      final shortCenterline = straightCenterline(lengthMeters: 300);
      final boat = boatAt(east: 10, north: 450, heading: 0);
      expect(
        evaluator.evaluateReverseGuidance(boat, shortCenterline),
        ReverseGuidanceOutcome.unverified,
      );
      final threat =
          reverseThreat(boat, [reverseZone], centerline: shortCenterline);
      expect(threat, isNotNull);
      expect(
        threat!.threat.continuousIntersection?.reasonCodes,
        contains('reverse_direction_unverified'),
      );
    });

    test('中心線から離れすぎた艇も縮退する', () {
      final boat = boatAt(
        east: maxChannelProjectionOffsetMeters + 10,
        north: 300,
        heading: 180,
      );
      expect(
        evaluator.evaluateReverseGuidance(boat, centerline),
        ReverseGuidanceOutcome.unverified,
      );
    });

    test('方位が信頼できない低速では逆走にしない', () {
      // 0.5m/s 未満では保持している進行方位が実際の艇の向きと最大90度ずれる。
      // 折り返しの回頭のたびに鳴らさない(不変条件10と同じ理由)。
      expect(shipDomainReliableHeadingSpeedMetersPerSecond, 0.5);
      expect(
        evaluator.evaluateReverseGuidance(
          boatAt(east: 10, north: 300, heading: 180, speed: 0.3),
          centerline,
        ),
        ReverseGuidanceOutcome.compliant,
      );
      expect(
        reverseThreat(
          boatAt(east: 10, north: 300, heading: 180, speed: 0.3),
          [reverseZone],
          centerline: centerline,
        ),
        isNull,
      );
    });

    test('カーブ区域の挙動は変わらない(進入で必ず発報し、理由コードも付かない)', () {
      final curveZone = zone(
        StaticObstacleKind.curve,
        southNorth: 100,
        northNorth: 500,
        id: 'curve_1',
      );
      for (final heading in [0.0, 90.0, 180.0]) {
        for (final speed in [4.0, 0.3]) {
          final assessment = evaluator.assessRisk(
            boatAt(east: 10, north: 300, heading: heading, speed: speed),
            const [],
            [curveZone],
            warningTimeSeconds: defaultWarningTimeSeconds,
            centerline: centerline,
          );
          final curve = assessment.threats
              .where((threat) =>
                  threat.threat.obstacleKind == StaticObstacleKind.curve)
              .toList();
          expect(curve, hasLength(1),
              reason: 'カーブは1カーブ1回で妥当に働いている。heading=$heading speed=$speed');
          expect(curve.single.threat.continuousIntersection, isNull);
        }
      }
    });

    test('区域の外にいれば、どの向きでも発報しない', () {
      expect(
        reverseThreat(
          boatAt(east: 10, north: 50, heading: 180),
          [reverseZone],
          centerline: centerline,
        ),
        isNull,
      );
    });
  });

  group('逆走注意の方向つき判定(実データ)', () {
    test('桜川の同梱プロファイルで方向判定が成立する', () async {
      final service = PresetObstacleService(
        includeTestZones: false,
        useLocalDangerZoneSettings: false,
        useLocalFixedObstacleCalibrations: false,
      );
      final obstacles = await service.loadPresets();
      final centerline = (await service
          .loadChannelCenterlines())['centerline_sakuragawa_estuary'];
      expect(centerline, isNotNull);

      final reverseZone = obstacles.firstWhere(
        (obstacle) => obstacle.kind == StaticObstacleKind.reverse,
      );
      // 区域の中で、中心線から十分離れた(レーン中央相当の)点を探す。
      LatLng? sample;
      ChannelFrame? sampleFrame;
      for (final point in reverseZone.points) {
        final frame = centerline!.project(point);
        if (!frame.isInsideCoverage) continue;
        if (frame.crossMeters.abs() <= reverseGuidanceLaneAmbiguityMeters) {
          continue;
        }
        if (frame.crossMeters.abs() > maxChannelProjectionOffsetMeters) {
          continue;
        }
        sample = point;
        sampleFrame = frame;
        break;
      }
      expect(sample, isNotNull, reason: '実データの逆走区域は中心線のカバー範囲内にあること');

      final tangent = centerline!.tangentBearingAt(sampleFrame!.alongMeters);
      final required =
          sampleFrame.crossMeters > 0 ? tangent : (tangent + 180) % 360;

      Boat boatHeading(double heading) => Boat(
            boatId: 'own',
            boatType: BoatType.r_1x,
            lat: sample!.latitude,
            lng: sample.longitude,
            heading: heading,
            speed: 4,
            timestamp: DateTime.now(),
            accuracy: 5,
          );

      expect(
        evaluator.evaluateReverseGuidance(boatHeading(required), centerline),
        ReverseGuidanceOutcome.compliant,
        reason: '実データでも、規定どおり漕いでいれば鳴らない',
      );
      expect(
        evaluator.evaluateReverseGuidance(
          boatHeading((required + 180) % 360),
          centerline,
        ),
        ReverseGuidanceOutcome.reverse,
      );
    });
  });
}
