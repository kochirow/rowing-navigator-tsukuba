import 'package:google_maps_flutter/google_maps_flutter.dart';

class StaticObstacle {
  final String id;
  final List<LatLng> points;

  StaticObstacle({
    required this.id,
    required this.points,
  });
}
