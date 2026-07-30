import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import 'package:rowing_navigator/models/static_obstacle_model.dart';
import 'package:rowing_navigator/services/safety_shape_overlay_service.dart';
import 'package:rowing_navigator/services/ship_domain_service.dart';
import 'package:rowing_navigator/types/boat_type.dart';

void main() {
  final service = SafetyShapeOverlayService();
  final now = DateTime.utc(2026, 7, 28, 9);

  Boat boat({double speed = 3, double? accuracy}) => Boat(
        boatId: 'boat-1',
        boatType: BoatType.r_1x,
        lat: 36.069,
        lng: 140.208,
        heading: 0,
        speed: speed,
        accuracy: accuracy,
        timestamp: now,
      );

  StaticObstacle obstacle({
    StaticObstacleKind kind = StaticObstacleKind.driftwood,
    bool enabled = true,
  }) =>
      StaticObstacle(
        id: 'obstacle-${kind.name}',
        kind: kind,
        isWarningEnabled: enabled,
        points: const [
          LatLng(36.07, 140.21),
          LatLng(36.0701, 140.21),
          LatLng(36.0701, 140.2101),
        ],
      );

  Polygon polygonById(Set<Polygon> overlay, String id) => overlay.firstWhere(
        (polygon) => polygon.polygonId.value == id,
      );

  double longitudeSpan(Polygon polygon) {
    final longitudes = polygon.points.map((point) => point.longitude);
    return longitudes.reduce((a, b) => a > b ? a : b) -
        longitudes.reduce((a, b) => a < b ? a : b);
  }

  group('SafetyShapeOverlayService', () {
    test('船体は通常表示と同じ実体形状を実線で追加する', () {
      final currentBoat = boat(speed: 0.1);
      final overlay = service.build(
        boat: currentBoat,
        obstacles: [obstacle()],
        warningTimeSeconds: 13,
      );

      final body = polygonById(
        overlay,
        'developer_shape_ship_body_${currentBoat.boatId}',
      );
      final normalMapBody = ShipDomainService()
          .getShipDomains(currentBoat, headingReliable: true)
          .shipBodyDomain;

      expect(body.points, normalMapBody.points);
      expect(body.strokeWidth, 3);
      expect(body.fillColor.a, 0);
    });

    test('有効な静的区域の kind ごとに実効掃引枠と予測掃引帯を作る', () {
      final currentBoat = boat(accuracy: 8);
      final overlay = service.build(
        boat: currentBoat,
        obstacles: [
          obstacle(kind: StaticObstacleKind.shore),
          obstacle(kind: StaticObstacleKind.driftwood),
        ],
        warningTimeSeconds: 13,
      );

      final ids = overlay.map((polygon) => polygon.polygonId.value).toSet();
      expect(ids, contains('developer_shape_static_sweep_now_boat-1_shore'));
      expect(
        ids,
        contains('developer_shape_static_sweep_now_boat-1_driftwood'),
      );
      expect(
        ids.any(
            (id) => id.startsWith('developer_shape_prediction_boat-1_shore_')),
        isTrue,
      );
      expect(
        ids.any(
          (id) => id.startsWith('developer_shape_prediction_boat-1_driftwood_'),
        ),
        isTrue,
      );

      final prediction = overlay.firstWhere((polygon) => polygon.polygonId.value
          .startsWith('developer_shape_prediction_boat-1_driftwood_'));
      expect(prediction.points.length, greaterThanOrEqualTo(6));
      expect(prediction.fillColor.a, 0);
    });

    test('静的掃引枠はGPS帯と低速時の横拡張を含む', () {
      final target = obstacle();
      final lowAccuracy = polygonById(
        service.build(
          boat: boat(speed: 3, accuracy: 20),
          obstacles: [target],
          warningTimeSeconds: 13,
        ),
        'developer_shape_static_sweep_now_boat-1_driftwood',
      );
      final highAccuracy = polygonById(
        service.build(
          boat: boat(speed: 3, accuracy: 4),
          obstacles: [target],
          warningTimeSeconds: 13,
        ),
        'developer_shape_static_sweep_now_boat-1_driftwood',
      );
      final stopped = polygonById(
        service.build(
          boat: boat(speed: 0.1, accuracy: 4),
          obstacles: [target],
          warningTimeSeconds: 13,
        ),
        'developer_shape_static_sweep_now_boat-1_driftwood',
      );

      expect(
          longitudeSpan(lowAccuracy), greaterThan(longitudeSpan(highAccuracy)));
      expect(longitudeSpan(stopped), greaterThan(longitudeSpan(highAccuracy)));
    });

    test('無効な区域と進入案内区域は静的判定形状へ含めない', () {
      final overlay = service.build(
        boat: boat(),
        obstacles: [
          obstacle(kind: StaticObstacleKind.curve),
          obstacle(kind: StaticObstacleKind.bridge, enabled: false),
        ],
        warningTimeSeconds: 13,
      );

      expect(overlay, hasLength(1));
      expect(
        overlay.single.polygonId.value,
        'developer_shape_ship_body_boat-1',
      );
    });
  });
}
