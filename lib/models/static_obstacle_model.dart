import 'package:google_maps_flutter/google_maps_flutter.dart';

class StaticObstacleModel {
  final String id;
  final List<LatLng> points;

  StaticObstacleModel({
    required this.id,
    required this.points,
  });
}
