import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/models/static_obstacle_model.dart';

void main() {
  test('橋脚の外周ポリゴンをシリアライズしても親の橋との関連を保持する', () {
    final obstacle = StaticObstacle(
      id: 'bridgepier_example_1',
      sourceId: 'bridgepier_example_1',
      bridgeId: 'bridge_example',
      kind: StaticObstacleKind.bridgePier,
      points: const [
        LatLng(36.07000, 140.20000),
        LatLng(36.07010, 140.19998),
        LatLng(36.07016, 140.20006),
        LatLng(36.07009, 140.20014),
        LatLng(36.06999, 140.20010),
      ],
    );

    expect(obstacle.toJson()['bridgeId'], 'bridge_example');
    expect(obstacle.toJson()['kind'], 'bridgePier');
    expect(obstacle.toJson()['points'], hasLength(5));
  });
}
