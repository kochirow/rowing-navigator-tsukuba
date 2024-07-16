import 'dart:async';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/api/staticObstacleAPI.dart';
import 'package:rowing_navigator/models/static_obstacle_model.dart';

class StaticObstacleService {
  final staticObstacleRef = StaticObstacleAPI();
  Stream<Map<String, dynamic>> getStaticObstaclesStream() {
    final staticObstaclesStream_ = staticObstacleRef.collection.snapshots();
    final staticObstaclesStream =
        staticObstaclesStream_.transform(StreamTransformer.fromBind((stream) {
      final controller = StreamController<Map<String, dynamic>>();
      stream.listen((snapshot) {
        List<StaticObstacle> obstacles = [];
        for (final doc in snapshot.docs) {
          final obstacle_ = doc.data();
          List<LatLng> points = (obstacle_["points"] as List<dynamic>)
              .map<LatLng>((point) => LatLng(point.latitude, point.longitude))
              .toList();
          final obstacle = StaticObstacle(id: obstacle_["id"], points: points);
          obstacles.add(obstacle);
        }
        controller.add({"obstacles": obstacles} as Map<String, dynamic>);
      });
      return controller.stream;
    }));
    return staticObstaclesStream;
  }
}
