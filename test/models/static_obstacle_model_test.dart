import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/models/static_obstacle_model.dart';

void main() {
  test('橋脚をシリアライズしても親の橋との関連を保持する', () {
    final obstacle = StaticObstacle(
      id: 'bridgepier_example_1',
      sourceId: 'bridgepier_example_1',
      bridgeId: 'bridge_example',
      kind: StaticObstacleKind.bridgePier,
      points: const [
        LatLng(36.0700, 140.2000),
        LatLng(36.0701, 140.2000),
        LatLng(36.0701, 140.2001),
      ],
    );

    expect(obstacle.toJson()['bridgeId'], 'bridge_example');
    expect(obstacle.toJson()['kind'], 'bridgePier');
  });
}
