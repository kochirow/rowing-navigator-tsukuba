import 'dart:async';
/* spellchecker: disable */
import '../models/boat_model.dart';
import 'dynamic_obstacle_service.dart';

class EnvService {
  final dynamicObstacleService = DynamicObstacleService();

  Stream<dynamic> getEnvStream() {
    // 将来的にStaticObstacleを含めてenvStreamに変換するして返す
    final dynamicObstacleStream =
        dynamicObstacleService.getDynamicObstacleStream();
    final envStream =
        dynamicObstacleStream.transform(StreamTransformer.fromBind((stream) {
      final controller = StreamController<Map<String, dynamic>>();
      stream.listen((dynamicObstacle) {
        controller.add({"boats": dynamicObstacle["boats"] as List<Boat>});
      });
      return controller.stream;
    }));
    return envStream;
  }
}
