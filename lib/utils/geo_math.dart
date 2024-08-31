import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:math';

// 度をラジアンに変換する関数
double degreesToRadians(double degrees) {
  return degrees * pi / 180.0;
}

// ラジアンを度に変換する関数
double radiansToDegrees(double radians) {
  return radians * 180.0 / pi;
}

// 指定した距離（メートル）と方位角（度）から地理座標を計算する関数
LatLng computeOffset(LatLng from, double distance, double heading) {
  const double earthRadius = 6378137; // 地球の半径（メートル）
  double angularDistance = distance / earthRadius;
  double bearing = degreesToRadians(heading);

  double fromLat = degreesToRadians(from.latitude);
  double fromLng = degreesToRadians(from.longitude);

  double toLat = asin(sin(fromLat) * cos(angularDistance) +
      cos(fromLat) * sin(angularDistance) * cos(bearing));
  double toLng = fromLng +
      atan2(sin(bearing) * sin(angularDistance) * cos(fromLat),
          cos(angularDistance) - sin(fromLat) * sin(toLat));

  return LatLng(radiansToDegrees(toLat), radiansToDegrees(toLng));
}
