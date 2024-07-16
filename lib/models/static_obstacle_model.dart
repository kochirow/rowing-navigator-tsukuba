import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class StaticObstacle {
  final String id;
  final List<LatLng> points;

  StaticObstacle({
    required this.id,
    required this.points,
  });

  Map<String, dynamic> toJson() {
    return {
      "points": points
          .map((point) => GeoPoint(point.latitude, point.longitude))
          .toList(),
    };
  }
}
