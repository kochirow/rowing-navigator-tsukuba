import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

Set<Circle> getShipArea(double lat, double lng) {
  LatLng latLng = LatLng(lat, lng);
  return {
    Circle(
      circleId: const CircleId('lv2'),
      center: latLng,
      radius: 200,
      fillColor: Colors.green.withOpacity(0.3),
      strokeWidth: 0,
      zIndex: -12,
    ),
    Circle(
      circleId: const CircleId('lv3'),
      center: latLng,
      radius: 100,
      fillColor: Colors.yellow.withOpacity(0.3),
      strokeWidth: 0,
      zIndex: -12,
    ),
    Circle(
      circleId: const CircleId('lv4'),
      center: latLng,
      radius: 50,
      fillColor: Colors.pink.withOpacity(0.3),
      strokeWidth: 0,
      zIndex: -11,
    ),
    Circle(
      circleId: const CircleId('lv5'),
      center: latLng,
      radius: 10,
      fillColor: Colors.red.withOpacity(0.5),
      strokeWidth: 0,
      zIndex: -10,
    ),
  };
}
