import 'package:google_maps_flutter/google_maps_flutter.dart';

LatLng getMeanLatLng(List<LatLng> positions) {
  if (positions.isEmpty) {
    throw ArgumentError('positions must not be empty');
  } else if (positions.length == 1) {
    return positions.first;
  } else {
    double sumLat = 0;
    double sumLng = 0;
    for (final newPoint in positions) {
      sumLat += newPoint.latitude;
      sumLng += newPoint.longitude;
    }
    final meanLat = sumLat / positions.length;
    final meanLng = sumLng / positions.length;
    return LatLng(meanLat, meanLng);
  }
}
