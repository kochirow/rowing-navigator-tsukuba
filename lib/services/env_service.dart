import 'dart:async';
/* spellchecker: disable */
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
}
