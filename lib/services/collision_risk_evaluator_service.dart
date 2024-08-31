import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/config/boat_config.dart';
import 'package:rowing_navigator/types/ship_domain_type.dart';
import 'package:rowing_navigator/utils/sat_algorithm.dart';
import 'package:rowing_navigator/services/ship_domain_service.dart';

import '../config/risk_evaluation_config.dart';
import '../models/boat_model.dart';
import '../models/static_obstacle_model.dart';
import '../types/collision_risk_level.dart';
import '../utils/geo_math.dart';

// 状況を表すクラス
class Situation {
  final Boat myBoat;
  final List<Boat> otherBoats;
  final List<StaticObstacle> obstacles;

  Situation({
    required this.myBoat,
    required this.otherBoats,
    required this.obstacles,
  });
}

class CollisionRiskEvaluatorService {
  double getStoppingDistance(Boat boat) {
    // return boatConfigs.byBoatType(boat.boatType).stoppingDistanceFormula(10);
    // 艇種ごとに停止距離を計算する
    return 50; // for development
  }

  Boat predictPosition(Boat boat, double afterSeconds) {
    const speed = 2.0; // for development / m/s
    double distance = speed * afterSeconds;
    final stoppingDistance = getStoppingDistance(boat); // for development
    // 停止距離を超える場合は移動距離を停止距離とする
    if (distance > stoppingDistance) {
      distance = stoppingDistance;
    }
    final newLatLng =
        computeOffset(LatLng(boat.lat, boat.lng), distance, boat.heading);
    final newBoat = Boat(
      boatId: boat.boatId,
      lat: newLatLng.latitude,
      lng: newLatLng.longitude,
      heading: boat.heading,
      boatType: boat.boatType,
      seatPos: boat.seatPos,
      timestamp: boat.timestamp,
    );
    return newBoat;
  }

  // 予測された状況を返す
  Situation predictSituation(Boat myBoat, List<Boat> otherBoats,
      List<StaticObstacle> obstacles, double afterSeconds) {
    Boat futureMyBoat = predictPosition(myBoat, afterSeconds);
    List<Boat> futureOtherBoats =
        otherBoats.map((boat) => predictPosition(boat, afterSeconds)).toList();
    final futureObstacles = obstacles;

    return Situation(
        myBoat: futureMyBoat,
        otherBoats: futureOtherBoats,
        obstacles: futureObstacles);
  }

  // その状況の衝突リスクを評価する
  CollisionRiskLevel evaluateCurrentRisk(
      Boat myBoat, List<Boat> otherBoats, List<StaticObstacle> obstacles) {
    CollisionRiskLevel level = CollisionRiskLevel.lv0;
    final shipDomainService = ShipDomainService();
    final myShipDomains = shipDomainService.getShipDomains(myBoat);
    final myShipBodyDomain = myShipDomains.shipBodyDomain;

    // ===========================
    // 障害物との衝突リスクを評価
    // ===========================
    for (final obstacle in obstacles) {
      for (final shipDomain in myShipDomains.allDomains) {
        final obstacleDomain = Polygon(
          polygonId: PolygonId(obstacle.id),
          points: obstacle.points,
        );
        try {
          final collide = polygonsOverlap(shipDomain, obstacleDomain);
          if (collide) {
            ShipDomainType shipDomainType =
                ShipDomainType.values.byName(shipDomain.polygonId.value);
            switch (shipDomainType) {
              case ShipDomainType.shipBodyDomain:
                level = CollisionRiskLevel.lv3.index > level.index
                    ? CollisionRiskLevel.lv3
                    : level;
                break;
              case ShipDomainType.exclusiveDomain:
                level = CollisionRiskLevel.lv2.index > level.index
                    ? CollisionRiskLevel.lv2
                    : level;
                break;
              case ShipDomainType.cautionDomain:
                level = CollisionRiskLevel.lv1.index > level.index
                    ? CollisionRiskLevel.lv1
                    : level;
                break;
              default:
                break;
            }
          }
        } catch (e) {
          print(e); // 衝突判定ができない場合は無視
        }
      }
    }

    // ===========================
    // 他艇との衝突リスクを評価
    // ===========================
    for (final otherBoat in otherBoats) {
      final otherShipDomains = shipDomainService.getShipDomains(otherBoat);
      final otherShipBodyDomain = otherShipDomains.shipBodyDomain;
      // 1. 自艇の各領域と他艇の船体領域との衝突判定
      for (final myShipDomain in myShipDomains.allDomains) {
        try {
          final collide = polygonsOverlap(myShipDomain, otherShipBodyDomain);
          if (collide) {
            ShipDomainType shipDomainType =
                ShipDomainType.values.byName(myShipDomain.polygonId.value);
            switch (shipDomainType) {
              case ShipDomainType.shipBodyDomain:
                level = CollisionRiskLevel.lv3.index > level.index
                    ? CollisionRiskLevel.lv3
                    : level;
                break;
              case ShipDomainType.exclusiveDomain:
                level = CollisionRiskLevel.lv2.index > level.index
                    ? CollisionRiskLevel.lv2
                    : level;
                break;
              case ShipDomainType.cautionDomain:
                level = CollisionRiskLevel.lv1.index > level.index
                    ? CollisionRiskLevel.lv1
                    : level;
                break;
              default:
                break;
            }
          }
        } catch (e) {
          print(e); // 衝突判定ができない場合は無視
        }
      }

      // 2. 自艇の船体領域と他艇の各領域との衝突判定
      for (final otherDomain in otherShipDomains.allDomains) {
        try {
          final collide = polygonsOverlap(otherDomain, myShipBodyDomain);
          if (collide) {
            ShipDomainType shipDomainType =
                ShipDomainType.values.byName(otherDomain.polygonId.value);
            switch (shipDomainType) {
              case ShipDomainType.shipBodyDomain:
                level = CollisionRiskLevel.lv3.index > level.index
                    ? CollisionRiskLevel.lv3
                    : level;
                break;
              case ShipDomainType.exclusiveDomain:
                level = CollisionRiskLevel.lv2.index > level.index
                    ? CollisionRiskLevel.lv2
                    : level;
                break;
              case ShipDomainType.cautionDomain:
                level = CollisionRiskLevel.lv1.index > level.index
                    ? CollisionRiskLevel.lv1
                    : level;
                break;
              default:
                break;
            }
          }
        } catch (e) {
          print(e); // 衝突判定ができない場合は無視
        }
      }
    }
    return level;
  }

  // その状況の将来の衝突リスクを評価する
  CollisionRiskLevel evaluateFutureRisk(
      Boat myBoat, List<Boat> otherBoats, List<StaticObstacle> obstacles) {
    CollisionRiskLevel level = CollisionRiskLevel.lv0;

    // すべての艇の最大経過時間を計算／最大経過時間は単に停止距離を現在の速さで割ったものであり最大停止時間とは関係ない
    double maxStoppingTime = 0;
    for (final boat in [myBoat, ...otherBoats]) {
      const speed = 2.0; // for development / m/s
      final stoppingDistance = getStoppingDistance(boat);
      final stoppingTime = stoppingDistance / speed;
      maxStoppingTime =
          stoppingTime > maxStoppingTime ? stoppingTime : maxStoppingTime;
    }

    // 最大経過時間の間の衝突リスクを評価
    for (double t = 0; t <= maxStoppingTime; t += deltaTime) {
      Situation futureSituation =
          predictSituation(myBoat, otherBoats, obstacles, t); // t秒後の状況を予測
      final newLevel = evaluateCurrentRisk(futureSituation.myBoat,
          futureSituation.otherBoats, futureSituation.obstacles);
      level = newLevel.index > level.index ? newLevel : level;
    }

    return level;
  }
}
