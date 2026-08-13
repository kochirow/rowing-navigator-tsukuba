import 'dart:async';
/* spellchecker: disable */
import 'package:rowing_navigator/models/static_obstacle_model.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'dynamic_obstacle_service.dart';
import 'message_service.dart';
import 'static_obstacle_service.dart';

class EnvService {
  final DynamicObstacleService dynamicObstacleService;
  final StaticObstacleService staticObstacleService;

  EnvService({MessageService? messageService})
      : dynamicObstacleService =
            DynamicObstacleService(messageService: messageService),
        staticObstacleService = StaticObstacleService();

  Stream<dynamic> getDynamicObstaclesStream() {
    return dynamicObstacleService.getDynamicObstaclesStream();
  }

  /// 臨時危険区域だけをFirestoreから取得する。
  /// 固定危険区域はPresetObstacleServiceから端末内で読み込む。
  Stream<dynamic> getTemporaryObstaclesStream() {
    return staticObstacleService.getStaticObstaclesStream();
  }

  /// 通常マップ用に、現在有効な臨時危険区域を一度だけ取得する。
  Future<Map<String, dynamic>> getCurrentTemporaryObstacles() {
    return staticObstacleService.fetchCurrentTemporaryObstacles();
  }

  Future<void> addTemporaryObstacle(StaticObstacle obstacle) async {
    await staticObstacleService.addStaticObstacle(obstacle);
  }

  Future<String> addTemporaryCircle(
    LatLng center, {
    double radiusMeters = StaticObstacleService.defaultTemporaryRadiusMeters,
  }) {
    return staticObstacleService.addTemporaryCircle(
      center: center,
      radiusMeters: radiusMeters,
    );
  }

  Future<void> updateTemporaryCircle(
    String obstacleId,
    LatLng center,
    double radiusMeters,
  ) {
    return staticObstacleService.updateTemporaryCircle(
      obstacleId: obstacleId,
      center: center,
      radiusMeters: radiusMeters,
    );
  }

  Future<void> deleteTemporaryObstacle(String obstacleId) async {
    await staticObstacleService.deleteStaticObstacle(obstacleId);
  }
}
