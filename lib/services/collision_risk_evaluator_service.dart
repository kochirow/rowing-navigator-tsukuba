import 'package:flutter_map_math/flutter_geo_math.dart';

import '../models/boat_model.dart';
import '../types/collision_risk_level.dart';

class CollisionRiskEvaluatorService {
  CollisionRiskLevel evaluateRisk(Boat myBoat, List<Boat> otherBoats) {
    CollisionRiskLevel level = CollisionRiskLevel.lv1;
    FlutterMapMath mapMath = FlutterMapMath();
    double nearestDistance = double.infinity;
    String closestBoatId = "";
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
      if (distance < 20) {
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
      } else if (distance < 150) {
        level = CollisionRiskLevel.lv2.index > level.index
            ? CollisionRiskLevel.lv2
            : level;
      } else {
        level = CollisionRiskLevel.lv1.index > level.index
            ? CollisionRiskLevel.lv1
            : level;
      }
    }
    print(
        "NearestBoatId: ${closestBoatId}, Distance: ${nearestDistance.toStringAsFixed(1)}m");
    return level;
  }
}
