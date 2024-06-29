import 'dart:async';
import 'package:rxdart/rxdart.dart';
/* spellchecker: disable */
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/boat_model.dart';
import '../services/dynamic_obstacle.dart';

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
