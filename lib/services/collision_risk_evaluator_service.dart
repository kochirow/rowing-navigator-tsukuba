import 'package:flutter_map_math/flutter_geo_math.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/utils/winding_algorithm.dart';

import '../models/boat_model.dart';
import '../models/static_obstacle_model.dart';
import '../types/collision_risk_level.dart';

class CollisionRiskEvaluatorService {
  CollisionRiskLevel evaluateRisk(
      Boat myBoat, List<Boat> otherBoats, List<StaticObstacle> obstacles) {
    CollisionRiskLevel level = CollisionRiskLevel.lv1;
    FlutterMapMath mapMath = FlutterMapMath();
    double nearestDistance = double.infinity;
    String closestBoatId = "";
    String closestObstacleId = "";
    for (final targetBoat in otherBoats) {
      final distance = mapMath.distanceBetween(
        myBoat.lat,
        myBoat.lng,
        targetBoat.lat,
        targetBoat.lng,
        "meters",
      );
      if (distance < nearestDistance) {
        nearestDistance = distance;
        closestBoatId = targetBoat.boatId;
      }
      if (distance < 10) {
        level = CollisionRiskLevel.lv5.index > level.index
            ? CollisionRiskLevel.lv5
            : level;
      } else if (distance < 50) {
        level = CollisionRiskLevel.lv4.index > level.index
            ? CollisionRiskLevel.lv4
            : level;
      } else if (distance < 100) {
        level = CollisionRiskLevel.lv3.index > level.index
            ? CollisionRiskLevel.lv3
            : level;
      } else if (distance < 200) {
        level = CollisionRiskLevel.lv2.index > level.index
            ? CollisionRiskLevel.lv2
            : level;
      } else {
        level = CollisionRiskLevel.lv1.index > level.index
            ? CollisionRiskLevel.lv1
            : level;
      }
    }
    for (final obstacle in obstacles) {
      final myBoatPos = LatLng(myBoat.lat, myBoat.lng);
      final isInside = isPointInPolygon(myBoatPos, obstacle.points);
      if (isInside) {
        level = CollisionRiskLevel.lv5.index > level.index
            ? CollisionRiskLevel.lv5
            : level;
      }
      for (final point in obstacle.points) {
        final distance = mapMath.distanceBetween(
          myBoat.lat,
          myBoat.lng,
          point.latitude,
          point.longitude,
          "meters",
        );
        if (distance < nearestDistance) {
          nearestDistance = distance;
          closestObstacleId = obstacle.id;
        }
        if (distance < 10) {
          level = CollisionRiskLevel.lv5.index > level.index
              ? CollisionRiskLevel.lv5
              : level;
        } else if (distance < 50) {
          level = CollisionRiskLevel.lv4.index > level.index
              ? CollisionRiskLevel.lv4
              : level;
        } else if (distance < 100) {
          level = CollisionRiskLevel.lv3.index > level.index
              ? CollisionRiskLevel.lv3
              : level;
        } else if (distance < 200) {
          level = CollisionRiskLevel.lv2.index > level.index
              ? CollisionRiskLevel.lv2
              : level;
        } else {
          level = CollisionRiskLevel.lv1.index > level.index
              ? CollisionRiskLevel.lv1
              : level;
        }
      }
    }
    print(
        "NearestBoatId: ${closestBoatId}, lat: ${myBoat.lat}, lng: ${myBoat.lng}, Distance: ${nearestDistance.toStringAsFixed(1)}m");
    print(
        "NearestObstacleId: ${closestObstacleId}, lat: ${myBoat.lat}, lng: ${myBoat.lng}, Distance: ${nearestDistance.toStringAsFixed(1)}m");
    return level;
  }
}
