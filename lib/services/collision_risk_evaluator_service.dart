import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/config/boat_config.dart';
import 'package:rowing_navigator/types/ship_domain_type.dart';
import 'package:rowing_navigator/utils/sat_algorithm.dart';
import 'package:rowing_navigator/services/ship_domain_service.dart';

import '../config/risk_evaluator_config.dart';
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
    // 艇種ごとに停止距離を計算する
    final speed = boat.speed;
    return boatConfigs.byBoatType(boat.boatType).stoppingDistanceFormula(speed);
  }

  Boat predictPosition(Boat boat, double afterSeconds) {
    final speed = boat.speed;
    double distance = speed * afterSeconds;
    final newLatLng =
        computeOffset(LatLng(boat.lat, boat.lng), distance, boat.heading);
    final newBoat = Boat(
      boatId: boat.boatId,
      lat: newLatLng.latitude,
      lng: newLatLng.longitude,
      heading: boat.heading,
      speed: boat.speed,
      boatType: boat.boatType,
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

  // その状況で衝突が発生しているか判定を行う
  bool checkCollision(
      Boat myBoat, List<Boat> otherBoats, List<StaticObstacle> obstacles) {
    final shipDomainService = ShipDomainService();
    final myShipDomains = shipDomainService.getShipDomains(myBoat);
    final myShipBodyDomain = myShipDomains.shipBodyDomain;

    // ===========================
    // 障害物との衝突リスクを評価
    // ===========================
    for (final obstacle in obstacles) {
      final obstacleDomain = Polygon(
        polygonId: PolygonId(obstacle.id),
        points: obstacle.points,
      );
      try {
        final collide = polygonsOverlap(myShipBodyDomain,
            obstacleDomain); // 自艇は船体領域で衝突判定を行う／停止時に余裕を持たせるなら排他領域で衝突判定を行う
        if (collide) return true;
      } catch (e) {
        print(e); // 衝突判定ができない場合は無視
      }
    }

    // ===========================
    // 他艇との衝突リスクを評価
    // ===========================
    for (final otherBoat in otherBoats) {
      final otherShipDomains = shipDomainService.getShipDomains(otherBoat);
      final otherShipBodyDomain = otherShipDomains.shipBodyDomain;
      // 1. 自艇の領域と他艇の船体領域との衝突判定
      try {
        final collide = polygonsOverlap(myShipBodyDomain,
            otherShipBodyDomain); // 自艇は船体領域で衝突判定を行う／停止時に余裕を持たせるなら排他領域で衝突判定を行う
        if (collide) return true;
      } catch (e) {
        print(e); // 衝突判定ができない場合は無視
      }

      // 2. 自艇の船体領域と他艇の領域との衝突判定
      try {
        final collide = polygonsOverlap(otherShipBodyDomain,
            myShipBodyDomain); // 他艇は船体領域で衝突判定を行う／停止時に余裕を持たせるなら排他領域で衝突判定を行う
        if (collide) return true;
      } catch (e) {
        print(e); // 衝突判定ができない場合は無視
      }
    }
    return false;
  }

  // その状況の将来の衝突リスクを評価する
  CollisionRiskLevel evaluateFutureRisk(
      Boat myBoat, List<Boat> otherBoats, List<StaticObstacle> obstacles) {
    CollisionRiskLevel level = CollisionRiskLevel.lv0;

    // 自艇が停止するまでの他艇および障害物との衝突リスクを評価
    final speed = myBoat.speed;
    final stoppingDistance = getStoppingDistance(myBoat);
    final warningDistance = stoppingDistance + speed * warningTime;
    final cautionDistance = warningDistance + speed * cautionTime;
    double t = 0;
    double deltaTime = speed == 0 ? -1 : evaluationInterval / speed;
    while (true) {
      final distance = speed * t;
      if (distance > cautionDistance) break;
      Situation futureSituation =
          predictSituation(myBoat, otherBoats, obstacles, t); // t秒後の状況を予測
      final isColliding = checkCollision(futureSituation.myBoat,
          futureSituation.otherBoats, futureSituation.obstacles);
      if (isColliding) {
        if (distance <= stoppingDistance) {
          level = CollisionRiskLevel.lv3.index > level.index
              ? CollisionRiskLevel.lv3
              : level;
        } else if (distance <= warningDistance) {
          level = CollisionRiskLevel.lv2.index > level.index
              ? CollisionRiskLevel.lv2
              : level;
        } else if (distance <= cautionDistance) {
          level = CollisionRiskLevel.lv1.index > level.index
              ? CollisionRiskLevel.lv1
              : level;
        }
      }
      if (speed == 0.0) break; // 艇が停止している場合は離脱
      t += deltaTime;
    }

    // 他艇が停止するまでの自艇との衝突リスクを評価
    for (final otherBoat in otherBoats) {
      final speed = otherBoat.speed;
      final stoppingDistance = getStoppingDistance(otherBoat);
      final warningDistance = stoppingDistance + speed * warningTime;
      final cautionDistance = warningDistance + speed * cautionTime;
      double t = 0;
      double deltaTime = speed == 0 ? -1 : evaluationInterval / speed;
      while (true) {
        final distance = speed * t;
        if (distance > cautionDistance) break;
        Situation futureSituation = predictSituation(
            myBoat, [otherBoat], [], t); // t秒後の状況を予測／対象の艇以外と障害物は無視
        final isColliding = checkCollision(futureSituation.myBoat,
            futureSituation.otherBoats, futureSituation.obstacles);
        if (isColliding) {
          if (distance <= stoppingDistance) {
            level = CollisionRiskLevel.lv3.index > level.index
                ? CollisionRiskLevel.lv3
                : level;
          } else if (distance <= warningDistance) {
            level = CollisionRiskLevel.lv2.index > level.index
                ? CollisionRiskLevel.lv2
                : level;
          } else if (distance <= cautionDistance) {
            level = CollisionRiskLevel.lv1.index > level.index
                ? CollisionRiskLevel.lv1
                : level;
          }
        }
        if (speed == 0.0) break; // 艇が停止している場合は離脱
        t += deltaTime;
      }
    }

    return level;
  }
}
