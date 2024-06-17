import 'dart:math';
import 'package:geolocator/geolocator.dart';

// =============================================
// 2点間の方位角を取得
// -180°〜180°の範囲で方位角の値を返す
// =============================================
double getHeading(Position from, Position to) {
  final double lat1 = from.latitude;
  final double lon1 = from.longitude;
  final double lat2 = to.latitude;
  final double lon2 = to.longitude;
  final double dLon = lon2 - lon1;
  final double y = sin(dLon) * cos(lat2);
  final double x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
  final double heading = atan2(y, x) * 180 / pi;
  return heading;
}
