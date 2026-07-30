import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/models/danger_zone_settings.dart';
import 'package:rowing_navigator/models/static_obstacle_model.dart';
import 'package:rowing_navigator/services/legacy_danger_zone_generator.dart';
import 'package:rowing_navigator/utils/geo_math.dart';

void main() {
  const start = LatLng(36.075432, 140.21382);
  const end = LatLng(36.075152, 140.21382);
  final generator = LegacyDangerZoneGenerator();

  test('岸は水面側5m/陸側15m、橋を含む他の既定値は片側5m', () {
    final defaults = DangerZoneSettings.defaults();
    expect(defaults[DangerZoneKind.shore].waterSideMeters, 5.0);
    expect(defaults[DangerZoneKind.shore].landSideMeters, 15.0);
    for (final kind in DangerZoneKind.values.where(
      (kind) => kind != DangerZoneKind.shore,
    )) {
      expect(defaults[kind].waterSideMeters, 5.0);
      expect(defaults[kind].landSideMeters, 5.0);
    }
  });

  test('基準線の-90度側と+90度側へ指定した実距離だけ広げる', () {
    final rectangle = generator.createDangerRectangle(
      start: start,
      end: end,
      waterSideMeters: 10,
      landSideMeters: 20,
    );
    expect(rectangle, hasLength(4));
    expect(distanceMeters(start, rectangle[0]), closeTo(10, 0.1));
    expect(distanceMeters(end, rectangle[1]), closeTo(10, 0.1));
    expect(distanceMeters(end, rectangle[2]), closeTo(20, 0.1));
    expect(distanceMeters(start, rectangle[3]), closeTo(20, 0.1));
    // 南向きの基準線では-90度側が東、+90度側が西になる。
    expect(rectangle[0].longitude, greaterThan(start.longitude));
    expect(rectangle[3].longitude, lessThan(start.longitude));
  });

  test('1本の基準線から辺ごとに固定危険区域を作る', () {
    final obstacles = generator.generate(
      baselines: const [
        DangerZoneBaseline(
          id: 'test',
          name: 'テスト',
          kind: DangerZoneKind.driftwood,
          points: [start, end, LatLng(36.0751, 140.214)],
        ),
      ],
      settings: DangerZoneSettings.defaults(),
      proximityCautionDistanceMeters: 0,
    );
    expect(obstacles, hasLength(2));
    expect(obstacles.every((obstacle) => obstacle.isDefault), isTrue);
    expect(
      obstacles.every(
        (obstacle) => obstacle.proximityCautionDistanceMeters == 0,
      ),
      isTrue,
    );
  });

  test('テスト区域は通常の危険区域として生成する', () {
    final obstacles = generator.generate(
      baselines: const [
        DangerZoneBaseline(
          id: 'test_zone',
          name: '陸上テスト区域',
          kind: DangerZoneKind.testZone,
          points: [start, end],
        ),
      ],
      settings: DangerZoneSettings.defaults(),
      proximityCautionDistanceMeters: 0,
    );
    expect(obstacles, hasLength(1));
    expect(obstacles.single.kind, StaticObstacleKind.testZone);
    expect(obstacles.single.proximityCautionDistanceMeters, 0);
  });
}
