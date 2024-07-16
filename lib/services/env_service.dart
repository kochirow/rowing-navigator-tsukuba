import 'dart:async';
/* spellchecker: disable */
import 'package:rowing_navigator/models/static_obstacle_model.dart';

import 'dynamic_obstacle_service.dart';
import 'static_obstacle_service.dart';

class EnvService {
  final dynamicObstacleService = DynamicObstacleService();
  final staticObstacleService = StaticObstacleService();

  Stream<dynamic> getDynamicObstaclesStream() {
    return dynamicObstacleService.getDynamicObstaclesStream();
  }

  Stream<dynamic> getStaticObstaclesStream() {
    return staticObstacleService.getStaticObstaclesStream();
  }

  Future<void> addStaticObstacle(StaticObstacle obstacle) async {
    await staticObstacleService.addStaticObstacle(obstacle);
  }

  Future<void> deleteStaticObstacle(String obstacleId) async {
    await staticObstacleService.deleteStaticObstacle(obstacleId);
  }
}
