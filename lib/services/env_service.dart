import 'dart:async';
/* spellchecker: disable */
import '../models/boat_model.dart';
import 'dynamic_obstacle_service.dart';

class EnvService {
  final dynamicObstacleService = DynamicObstacle();

  Stream<dynamic> getEnvStream() {
    // 将来的にStaticObstacleを含めてenvStreamに変換するして返す
    final boatsStream = dynamicObstacleService.getBoatsStream();
    final envStream =
        boatsStream.transform(StreamTransformer.fromBind((stream) {
      final controller = StreamController<Map<String, dynamic>>();
      stream.listen((boats) {
        controller.add({"boats": boats as List<Boat>});
      });
      return controller.stream;
    }));
    return envStream;
  }
}
