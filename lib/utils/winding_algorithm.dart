import 'package:google_maps_flutter/google_maps_flutter.dart';

int windingNumber(LatLng point, List<LatLng> polygon) {
  int wn = 0; // winding number counter

  for (int i = 0; i < polygon.length; i++) {
    LatLng start = polygon[i];
    LatLng end = polygon[(i + 1) % polygon.length];

    if (start.latitude <= point.latitude) {
      if (end.latitude > point.latitude) {
        if (isLeft(start, end, point) > 0) {
          wn++;
        }
      }
    } else {
      if (end.latitude <= point.latitude) {
        if (isLeft(start, end, point) < 0) {
          wn--;
        }
      }
    }
  }

  return wn;
}

double isLeft(LatLng start, LatLng end, LatLng point) {
  return (end.longitude - start.longitude) * (point.latitude - start.latitude) -
      (point.longitude - start.longitude) * (end.latitude - start.latitude);
}

bool isPointInPolygon(LatLng point, List<LatLng> polygon) {
  return windingNumber(point, polygon) != 0;
}

// // 使用例
// LatLng point = LatLng(37.7749, -122.4194); // 例のポイント
// List<LatLng> polygon = [
//   LatLng(37.7797, -122.4184),
//   LatLng(37.7787, -122.4220),
//   LatLng(37.7737, -122.4240),
//   LatLng(37.7727, -122.4184),
//   LatLng(37.7797, -122.4184)
// ]; // 例のポリゴン

// bool isInside = isPointInPolygon(point, polygon);
// print(isInside); // true または false
