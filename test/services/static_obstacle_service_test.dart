import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/services/static_obstacle_service.dart';
import 'package:rowing_navigator/utils/geo_math.dart';

void main() {
  test('タップ地点を中心にデフォルト半径5mの円を生成する', () {
    final service = StaticObstacleService();
    const center = LatLng(36.075, 140.214);
    final points = service.createCirclePoints(
      center,
      StaticObstacleService.defaultTemporaryRadiusMeters,
    );
    expect(points, hasLength(StaticObstacleService.circlePointCount));
    expect(
      points.every(
        (point) =>
            distanceMeters(center, point) > 4.9 &&
            distanceMeters(center, point) < 5.1,
      ),
      isTrue,
    );
  });
}
