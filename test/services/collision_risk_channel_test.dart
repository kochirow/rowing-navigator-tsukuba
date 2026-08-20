import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/config/boat_config.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import 'package:rowing_navigator/models/static_obstacle_model.dart';
import 'package:rowing_navigator/services/channel_centerline.dart';
import 'package:rowing_navigator/services/collision_risk_evaluator_service.dart';
import 'package:rowing_navigator/services/ship_domain_service.dart';
import 'package:rowing_navigator/types/boat_type.dart';
import 'package:rowing_navigator/types/collision_risk_level.dart';
import 'package:rowing_navigator/utils/geo_math.dart';

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

Boat boatAt(
  LatLng position, {
  required double heading,
  double speed = 4,
  String boatId = 'own',
  BoatType type = BoatType.r_1x,
  double? accuracy,
}) =>
    Boat(
      boatId: boatId,
      boatType: type,
      lat: position.latitude,
      lng: position.longitude,
      heading: heading,
      speed: speed,
      timestamp: DateTime.now(),
      accuracy: accuracy,
    );

/// 桜川相当の蛇行区間。半径150m・川幅50mの右カーブ。
/// 中心線と、その左右25mに沿った岸の危険区域(帯)を作る。
({ChannelCenterline centerline, List<StaticObstacle> banks}) curvedRiver({
  double radius = 150,
  double halfWidth = 25,
  double sweepDegrees = 120,
}) {
  final centerPoints = <LatLng>[];
  for (var degrees = 0.0; degrees <= sweepDegrees; degrees += 4) {
    final radians = degrees * math.pi / 180;
    centerPoints.add(at(
      east: radius * (1 - math.cos(radians)),
      north: radius * math.sin(radians),
    ));
  }
  final centerline = ChannelCenterline.fromPolyline(centerPoints)!;

  // 岸の危険区域は、実装と同じく「基準線の各辺を長方形にしたもの」に倣い、
  // 中心線から halfWidth 離れた線に沿った細長い四角形の列にする。
  List<StaticObstacle> bankRibbons(double side, String prefix) {
    final ribbons = <StaticObstacle>[];
    const step = 20.0;
    for (var along = 0.0;
        along + step <= centerline.lengthMeters;
        along += step) {
      final innerStart = centerline.toLatLng(
          alongMeters: along, crossMeters: side * halfWidth);
      final innerEnd = centerline.toLatLng(
        alongMeters: along + step,
        crossMeters: side * halfWidth,
      );
      final outerStart = centerline.toLatLng(
        alongMeters: along,
        crossMeters: side * (halfWidth + 10),
      );
      final outerEnd = centerline.toLatLng(
        alongMeters: along + step,
        crossMeters: side * (halfWidth + 10),
      );
      ribbons.add(StaticObstacle(
        id: '$prefix-${along.round()}',
        kind: StaticObstacleKind.shore,
        points: [innerStart, innerEnd, outerEnd, outerStart],
      ));
    }
    return ribbons;
  }

  return (
    centerline: centerline,
    banks: [...bankRibbons(1, 'right'), ...bankRibbons(-1, 'left')],
  );
}

void main() {
  final evaluator = CollisionRiskEvaluatorService();

  group('航路中心線に沿った予測', () {
    test('カーブを川なりに進む艇へ、直線予測が出す誤警告を出さない', () {
      // 桜川の急な蛇行区間を想定した半径80mのカーブ。
      final river = curvedRiver(radius: 80);
      // 右カーブなので外岸は左(cross が負)側。外岸寄りを接線方向へ4m/s。
      // 10秒で40m進むため、直線予測は 40²/(2·80) ≒ 10m 外岸側へ膨らむ。
      const along = 60.0;
      final start =
          river.centerline.toLatLng(alongMeters: along, crossMeters: -14);
      final boat = boatAt(
        start,
        heading: river.centerline.tangentBearingAt(along),
      );

      final straight = evaluator.assessRisk(boat, [], river.banks);
      final channelAware = evaluator.assessRisk(
        boat,
        [],
        river.banks,
        centerline: river.centerline,
      );

      // 前提: 直線予測はカーブの外岸へ突っ込むので、衝突予測(lv2以上)が出る。
      expect(
        straight.level.index,
        greaterThanOrEqualTo(CollisionRiskLevel.lv2.index),
        reason: '前提: 直線予測ではカーブで衝突予測の誤警告が出ること',
      );
      expect(
        straight.threats.any((threat) =>
            threat.threat.continuousIntersection?.intersects ?? false),
        isTrue,
      );

      // 中心線に沿った予測なら、川なりに進む艇へ衝突予測は出ない。
      // 岸との近接注意(lv1・表示のみ)は別経路なので残ってよい。
      expect(channelAware.level.index,
          lessThanOrEqualTo(CollisionRiskLevel.lv1.index));
      expect(
        channelAware.threats.any((threat) =>
            threat.threat.continuousIntersection?.intersects ?? false),
        isFalse,
        reason: '川なりに進む艇へ、掃引由来の衝突予測を出さないこと',
      );
    });

    test('カーブでも岸へ向かう艇には確実に警告する(警告漏れを作らない)', () {
      final river = curvedRiver();
      const along = 60.0;
      final start =
          river.centerline.toLatLng(alongMeters: along, crossMeters: 0);
      // 接線から40度、右岸側へ向ける。
      final boat = boatAt(
        start,
        heading: river.centerline.tangentBearingAt(along) + 40,
      );

      final assessment = evaluator.assessRisk(
        boat,
        [],
        river.banks,
        centerline: river.centerline,
      );

      expect(assessment.level.index,
          greaterThanOrEqualTo(CollisionRiskLevel.lv2.index));
      expect(assessment.primaryThreat?.kind, ThreatKind.obstacle);
    });

    test('中心線があってもなくても、直線区間の判定は変わらない', () {
      final straightPoints = [
        at(east: 0, north: 0),
        at(east: 0, north: 400),
      ];
      final centerline = ChannelCenterline.fromPolyline(straightPoints)!;
      final obstacle = StaticObstacle(
        id: 'ahead',
        kind: StaticObstacleKind.driftwood,
        points: [
          at(east: -5, north: 25),
          at(east: 5, north: 25),
          at(east: 5, north: 35),
          at(east: -5, north: 35),
        ],
      );
      final boat = boatAt(at(east: 0, north: 0), heading: 0);

      expect(
        evaluator.assessRisk(boat, [], [obstacle]).level,
        evaluator
            .assessRisk(boat, [], [obstacle], centerline: centerline)
            .level,
      );
    });

    test('曲率マージンは有界で、直線の川では0になる', () {
      final straight = ChannelCenterline.fromPolyline([
        at(east: 0, north: 0),
        at(east: 0, north: 400),
      ])!;
      final boat = boatAt(at(east: 0, north: 10), heading: 0);
      expect(
        evaluator.channelCurvatureMarginMeters(boat, 10, straight),
        closeTo(0, 0.05),
      );

      final tight = curvedRiver(radius: 40, sweepDegrees: 170).centerline;
      final onTight = boatAt(
        tight.pointAt(10),
        heading: tight.tangentBearingAt(10),
      );
      final margin = evaluator.channelCurvatureMarginMeters(onTight, 10, tight);
      expect(margin, greaterThan(0));
      expect(margin, lessThanOrEqualTo(3.0));

      // 中心線が無ければマージンは加えない(従来と同じ判定)。
      expect(evaluator.channelCurvatureMarginMeters(onTight, 10, null), 0);
    });

    test('逆向き航行ではalongが減る側の非対称カーブを参照する', () {
      // 始点側だけが曲がり、終点側は直線の中心線。直線との接続点から
      // 正方向へ進めば曲率0、逆方向へ進めばカーブへ入る配置にする。
      final asymmetric = ChannelCenterline.fromPolyline([
        at(east: -60, north: -30),
        at(east: -45, north: -10),
        at(east: -25, north: 5),
        at(east: 0, north: 10),
        at(east: 80, north: 10),
        at(east: 160, north: 10),
      ])!;
      final startFrame = asymmetric.project(at(east: 5, north: 10));
      final tangent = startFrame.tangentBearingDegrees;
      final forward = boatAt(
        at(east: 5, north: 10),
        heading: tangent,
        speed: 4,
      );
      final reverse = boatAt(
        at(east: 5, north: 10),
        heading: (tangent + 180) % 360,
        speed: 4,
      );
      final unknownHeading = boatAt(
        at(east: 5, north: 10),
        heading: double.nan,
        speed: 4,
      );

      final reverseMargin =
          evaluator.channelCurvatureMarginMeters(reverse, 10, asymmetric);
      expect(
        evaluator.channelCurvatureMarginMeters(forward, 10, asymmetric),
        closeTo(0, 0.05),
        reason: '正方向は直線側なので曲率余裕を足さない',
      );
      expect(
        reverseMargin,
        greaterThan(0.5),
        reason: '逆方向はalongが減る側のカーブを参照する',
      );
      expect(
        evaluator.channelCurvatureMarginMeters(unknownHeading, 10, asymmetric),
        closeTo(reverseMargin, 1e-9),
        reason: '方位不明を理由に曲率余裕を小さくしない',
      );
    });
  });

  group('すれ違い間隔(DCPA)', () {
    test('領域が重ならなくても、極端に狭いすれ違いは注意にする', () {
      // 北向きと南向きの1xが、東西に少しずれてすれ違う。
      final own = boatAt(at(east: 0, north: 0), heading: 0, accuracy: 3);
      // 排他領域(幅9m)＋船体領域(幅6m)の半幅の和は 4.5+3=7.5m。
      // 8.5m離せば重ならないが、隙間は1mしかない。
      final other = boatAt(
        at(east: 8.5, north: 60),
        heading: 180,
        boatId: 'other',
        accuracy: 3,
      );

      final assessment = evaluator.assessRisk(own, [other], const []);

      expect(assessment.level, CollisionRiskLevel.lv1);
      final threat = assessment.primaryThreat;
      expect(threat?.kind, ThreatKind.boat);
      expect(threat?.separationMeters, isNotNull);
      expect(threat?.separationMeters, lessThanOrEqualTo(2.0));
      expect(
        threat?.continuousIntersection?.reasonCodes,
        contains('near_miss_separation'),
      );
    });

    test('十分に離れたすれ違いは警告しない', () {
      final own = boatAt(at(east: 0, north: 0), heading: 0, accuracy: 3);
      final other = boatAt(
        at(east: 25, north: 60),
        heading: 180,
        boatId: 'other',
        accuracy: 3,
      );

      expect(
        evaluator.assessRisk(own, [other], const []).level,
        CollisionRiskLevel.lv0,
      );
    });

    test('衝突コースでは separationMeters が0になる', () {
      final own = boatAt(at(east: 0, north: 0), heading: 0, accuracy: 3);
      final other = boatAt(
        at(east: 0, north: 40),
        heading: 180,
        boatId: 'other',
        accuracy: 3,
      );

      final assessment = evaluator.assessRisk(own, [other], const []);
      expect(assessment.level.index,
          greaterThanOrEqualTo(CollisionRiskLevel.lv2.index));
      expect(assessment.primaryThreat?.separationMeters, 0);
    });
  });

  group('低速時の方位不確かさ', () {
    test('低速では横方向へ有界に広げ、方位90度誤差で領域が痩せないようにする', () {
      final service = ShipDomainService();
      final params = boatConfigs.r_8p_.shipDomainParams.exclusiveParam;

      final moving = boatAt(at(east: 0, north: 0), heading: 0, speed: 4);
      final stopped = boatAt(at(east: 0, north: 0), heading: 0, speed: 0.1);

      double width(Boat boat) {
        final points = service.getShipDomains(boat).exclusiveDomain.points;
        var minEast = double.infinity;
        var maxEast = double.negativeInfinity;
        for (final point in points) {
          final east = (point.longitude - originLongitude) *
              metersPerLatitudeDegree *
              math.cos(originLatitude * math.pi / 180);
          minEast = math.min(minEast, east);
          maxEast = math.max(maxEast, east);
        }
        return maxEast - minEast;
      }

      final movingWidth = width(moving);
      final stoppedWidth = width(stopped);
      expect(stoppedWidth, greaterThan(movingWidth));
      // 上限4m/側を超えて広がらない。
      expect(stoppedWidth - movingWidth, lessThanOrEqualTo(8.2));
      expect(
        ShipDomainService.lowSpeedLateralInflationMeters(params),
        lessThanOrEqualTo(4.0),
      );
    });

    test('地図描画は headingReliable:true で従来の形状を保つ', () {
      final service = ShipDomainService();
      final stopped = boatAt(at(east: 0, north: 0), heading: 0, speed: 0.1);
      final moving = boatAt(at(east: 0, north: 0), heading: 0, speed: 4);

      final rendered = service
          .getShipDomains(stopped, headingReliable: true)
          .exclusiveDomain;
      final reference = service.getShipDomains(moving).exclusiveDomain;

      expect(rendered.points.length, reference.points.length);
      for (var index = 0; index < rendered.points.length; index++) {
        expect(rendered.points[index].latitude,
            closeTo(reference.points[index].latitude, 1e-9));
        expect(rendered.points[index].longitude,
            closeTo(reference.points[index].longitude, 1e-9));
      }
    });

    test('到達距離の見積りが領域の実寸を下回らない(全艇種・低速/巡航)', () {
      // broad-phase の到達半径が領域の実寸より小さいと、拡張したはずの
      // 領域が触れる障害物を評価前に捨ててしまう。
      // 「見積り半径 >= 実際の領域の最遠頂点距離」を全艇種で固定する。
      final service = ShipDomainService();

      double maxVertexDistance(Boat boat) {
        final points = service.getShipDomains(boat).exclusiveDomain.points;
        var farthest = 0.0;
        for (final point in points) {
          farthest = math.max(
            farthest,
            distanceMeters(LatLng(boat.lat, boat.lng), point),
          );
        }
        return farthest;
      }

      for (final type in BoatType.values) {
        for (final speed in [0.1, 4.0]) {
          final boat = boatAt(
            at(east: 0, north: 0),
            heading: 20,
            speed: speed,
            type: type,
          );
          expect(
            ShipDomainService.effectiveExclusiveRadius(boat),
            greaterThanOrEqualTo(maxVertexDistance(boat) - 0.01),
            reason: '$type @ ${speed}m/s',
          );
          // 低速拡張で `s`(前後方向)まで広げると六角形が凹になり、
          // 実効的な全長が伸びる。広げるのは横方向 `w` だけであること。
          final params =
              ShipDomainService.effectiveParamsFor(boat).exclusiveParam;
          expect(
            params.s,
            lessThanOrEqualTo(params.h),
            reason: '$type @ ${speed}m/s は凸六角形でなければならない',
          );
        }
      }
    });

    test('低速で広げた領域が触れる区域を broad-phase で捨てない', () {
      // 停止寸前の8+。領域の最遠頂点の位置に小さな区域を置き、
      // 評価対象から落ちないことを確認する。
      final service = ShipDomainService();
      final stopped = boatAt(
        at(east: 0, north: 0),
        heading: 0,
        speed: 0.1,
        type: BoatType.r_8p,
      );
      final center = LatLng(stopped.lat, stopped.lng);

      LatLng farthestVertexOf(List<LatLng> polygon) {
        var farthest = polygon.first;
        for (final point in polygon) {
          if (distanceMeters(center, point) >
              distanceMeters(center, farthest)) {
            farthest = point;
          }
        }
        return farthest;
      }

      // 最遠頂点をまたぐ小さな区域。
      StaticObstacle obstacleAt(LatLng vertex, StaticObstacleKind kind) =>
          StaticObstacle(
            id: 'far-vertex',
            kind: kind,
            points: [
              computeOffset(vertex, 1.0, 180),
              computeOffset(computeOffset(vertex, 1.0, 180), 2.0, 90),
              computeOffset(computeOffset(vertex, 1.0, 0), 2.0, 90),
              computeOffset(vertex, 1.0, 0),
            ],
          );

      // 生パラメータの外接半径より確実に遠い位置であることを前提確認。
      final rawRadius = ShipDomainService.boundingRadius(
        boatConfigs.r_8p_.shipDomainParams.exclusiveParam,
      );

      // 1) 既定クリアランス(=排他領域と同じ横幅)の区域。
      //    中州は近接注意5mでは届かない距離なので、掃引だけが根拠になる。
      final exclusiveVertex = farthestVertexOf(
        service.getShipDomains(stopped).exclusiveDomain.points,
      );
      expect(distanceMeters(center, exclusiveVertex), greaterThan(rawRadius),
          reason: '前提: 低速の拡張で領域が生半径より外へ伸びること');
      expect(
        evaluator
            .assessRisk(stopped, [],
                [obstacleAt(exclusiveVertex, StaticObstacleKind.island)])
            .level
            .index,
        greaterThan(CollisionRiskLevel.lv0.index),
        reason: '低速で広げた領域が触れる区域は必ず評価対象に残ること',
      );

      // 2) 岸は掃引の横幅を船体領域の実寸まで詰めてある。詰めた後の領域が
      //    触れる位置でも、broad-phase(排他領域ベースの到達半径)で
      //    捨てられないこと。半径を絞っていないことの回帰。
      final shoreVertex = farthestVertexOf(
        service
            .getStaticSweepDomain(
              stopped,
              clearancePerSideMeters:
                  StaticObstacleKind.shore.staticSweepClearanceMeters,
              lowSpeedLateralInflationFactor: StaticObstacleKind
                  .shore.staticSweepLowSpeedLateralInflationFactor,
            )
            .points,
      );
      // 不変条件8: 岸の掃引領域は排他領域の実効半径を超えない。
      // broad-phase(排他領域ベース)が保守側であり続けることの前提。
      expect(
        distanceMeters(center, shoreVertex),
        lessThanOrEqualTo(
          ShipDomainService.effectiveExclusiveRadius(stopped) + 1e-6,
        ),
      );
      expect(
        evaluator
            .assessRisk(stopped, [],
                [obstacleAt(shoreVertex, StaticObstacleKind.shore)])
            .level
            .index,
        greaterThan(CollisionRiskLevel.lv0.index),
        reason: '岸でも、掃引領域が触れる区域は評価対象に残ること',
      );
    });

    test('危険区域の内部にいる間は近接注意も必ず立つ(掃引判定の予備)', () {
      // 近接注意距離0の区域(区域自体に余裕を含む形状)でも、内部にいる事実は
      // 掃引が失敗した場合の予備として拾う必要がある。
      final boat = boatAt(at(east: 0, north: 0), heading: 0, speed: 0.2);
      final obstacle = StaticObstacle(
        id: 'embedded-margin',
        kind: StaticObstacleKind.shore,
        isDefault: true,
        proximityCautionDistanceMeters: 0,
        points: [
          at(east: -30, north: -30),
          at(east: 30, north: -30),
          at(east: 30, north: 30),
          at(east: -30, north: 30),
        ],
      );

      final threats = evaluator.findProximityThreats(boat, [obstacle]);
      expect(threats, isNotEmpty);
      expect(threats.first.distanceMeters, lessThan(0));
    });

    test('方位が180度ずれても領域の形は変わらない(バックは特別扱い不要)', () {
      final service = ShipDomainService();
      final forward = boatAt(at(east: 0, north: 0), heading: 30, speed: 3);
      final backward = boatAt(at(east: 0, north: 0), heading: 210, speed: 3);

      final a = service.getShipDomains(forward).exclusiveDomain.points;
      final b = service.getShipDomains(backward).exclusiveDomain.points;

      // 六角形は中心について点対称なので、頂点集合が一致する。
      for (final point in a) {
        expect(
          b.any((other) =>
              (other.latitude - point.latitude).abs() < 1e-9 &&
              (other.longitude - point.longitude).abs() < 1e-9),
          isTrue,
          reason: '$point が逆向きの領域に見つからない',
        );
      }
    });
  });

  group('低速時の方位不確かさと方向案内', () {
    // 折り返しの回頭中(speed<0.5)は領域が横へ最大4m広がる。その拡張ぶんで
    // しか重ならない通過艇まで「確実(=連続音)」にすると、回頭のたびに鳴って
    // 警告が形骸化する。検知は残したまま確度だけ下げること。
    test('回頭中の低速拡張だけで重なる他艇は、検知は残しつつ確度を下げる', () {
      final service = CollisionRiskEvaluatorService();
      // 8+ が回頭中(0.1m/s)。排他領域の半幅は (10.5+8)/2 = 9.25m。
      final spinning = boatAt(
        at(east: 0, north: 0),
        heading: 0,
        speed: 0.1,
        boatId: 'own',
        type: BoatType.r_8p,
        accuracy: 4,
      );
      // 12.5m 横を通過する艇。船体領域の半幅は 7.5/2 = 3.75m。
      // 9.25 + 3.75 = 13.0m > 12.5m なので拡張後だけ重なる。
      final passing = boatAt(
        at(east: 12.5, north: -30),
        heading: 0,
        speed: 4,
        boatId: 'passing',
        type: BoatType.r_8p,
        accuracy: 4,
      );

      final assessment = service.assessRisk(spinning, [passing], const []);
      final boatThreat = assessment.threats
          .where((threat) => threat.threat.kind == ThreatKind.boat)
          .toList();

      // 検知そのものは失われない。
      expect(boatThreat, isNotEmpty);
      final threat = boatThreat.first.threat;
      expect(threat.confidence, ThreatConfidence.uncertain);
      expect(
        threat.continuousIntersection?.reasonCodes,
        contains('heading_uncertainty_entry'),
      );
      // 「いま確実に重なっている」とは言わない(連続音まで上げない)。
      expect(threat.continuousIntersection?.currentOverlap, isFalse);
      expect(threat.continuousIntersection!.confidence, lessThan(1.0));
    });

    test('方位が信頼できる速度域では、重なりは従来どおり確実として扱う', () {
      final service = CollisionRiskEvaluatorService();
      final own = boatAt(
        at(east: 0, north: 0),
        heading: 0,
        speed: 4,
        boatId: 'own',
        type: BoatType.r_8p,
        accuracy: 4,
      );
      // 拡張なしの半幅 5.25 + 3.75 = 9.0m。8m なら確実に重なる。
      final other = boatAt(
        at(east: 8, north: 0),
        heading: 0,
        speed: 4,
        boatId: 'other',
        type: BoatType.r_8p,
        accuracy: 4,
      );

      final assessment = service.assessRisk(own, [other], const []);
      final threat = assessment.threats
          .firstWhere((threat) => threat.threat.kind == ThreatKind.boat)
          .threat;
      expect(threat.confidence, ThreatConfidence.definite);
      expect(
        threat.continuousIntersection?.reasonCodes,
        isNot(contains('heading_uncertainty_entry')),
      );
    });

    test('方位が信頼できるときだけ、脅威の相対方位を案内に使う', () {
      final service = CollisionRiskEvaluatorService();
      final moving = boatAt(
        at(east: 0, north: 0),
        heading: 0, // 北へ進行
        speed: 4,
        boatId: 'own',
        type: BoatType.r_1x,
        accuracy: 4,
      );
      final starboard = boatAt(
        at(east: 8, north: 0), // 真東 = 進行方向の右舷
        heading: 180,
        speed: 4,
        boatId: 'other',
        type: BoatType.r_1x,
        accuracy: 4,
      );

      final threat = service
          .assessRisk(moving, [starboard], const [])
          .threats
          .firstWhere((threat) => threat.threat.kind == ThreatKind.boat)
          .threat;
      expect(threat.relativeBearingDegrees, isNotNull);
      expect(threat.relativeBearingDegrees, closeTo(90, 15));

      // 回頭中は保持している方位が実際の艇の向きと最大90度ずれる。
      // 誤った側へ振り向かせるより、方向を出さないほうが安全。
      final spinning = boatAt(
        at(east: 0, north: 0),
        heading: 0,
        speed: 0.1,
        boatId: 'own',
        type: BoatType.r_1x,
        accuracy: 4,
      );
      final spinningThreat = service
          .assessRisk(spinning, [starboard], const [])
          .threats
          .firstWhere((threat) => threat.threat.kind == ThreatKind.boat)
          .threat;
      expect(spinningThreat.relativeBearingDegrees, isNull);
    });
  });
}
