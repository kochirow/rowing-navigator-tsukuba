import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/models/static_obstacle_model.dart';
import 'package:rowing_navigator/services/preset_obstacle_service.dart';
import 'package:rowing_navigator/services/static_obstacle_index.dart';
import 'package:rowing_navigator/utils/geo_proximity.dart';
import 'package:shared_preferences/shared_preferences.dart';

const originLatitude = 36.08;
const originLongitude = 140.12;
const metersPerLatitudeDegree = 111195.08;

LatLng at({required double east, required double north}) => LatLng(
      originLatitude + north / metersPerLatitudeDegree,
      originLongitude +
          east /
              (metersPerLatitudeDegree *
                  math.cos(originLatitude * math.pi / 180)),
    );

StaticObstacle squareAt({
  required String id,
  required double east,
  required double north,
  double halfSize = 5,
}) =>
    StaticObstacle(
      id: id,
      kind: StaticObstacleKind.shore,
      points: [
        at(east: east - halfSize, north: north - halfSize),
        at(east: east + halfSize, north: north - halfSize),
        at(east: east + halfSize, north: north + halfSize),
        at(east: east - halfSize, north: north + halfSize),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('StaticObstacleIndex', () {
    test('半径内の区域だけを返し、遠い区域は除く', () {
      final index = StaticObstacleIndex([
        squareAt(id: 'near', east: 0, north: 20),
        squareAt(id: 'mid', east: 0, north: 120),
        squareAt(id: 'far', east: 0, north: 800),
      ]);

      final ids = index
          .query(at(east: 0, north: 0), 40)
          .map((obstacle) => obstacle.id)
          .toSet();

      expect(ids, contains('near'));
      expect(ids, isNot(contains('far')));
    });

    test('境界上の区域を落とさない(保守的な上位集合であること)', () {
      // 100m離れた区域を、ちょうど届く半径で引く。
      final index = StaticObstacleIndex([
        squareAt(id: 'edge', east: 0, north: 100, halfSize: 5),
      ]);
      // 最寄りの辺は95m先。
      expect(index.query(at(east: 0, north: 0), 96), hasLength(1));
      expect(index.query(at(east: 0, north: 0), 90), isEmpty);
    });

    test('全件走査と同じ結果集合を含む(索引が答えを変えない)', () {
      final random = math.Random(7);
      final obstacles = <StaticObstacle>[
        for (var i = 0; i < 300; i++)
          squareAt(
            id: 'o$i',
            east: random.nextDouble() * 1200 - 600,
            north: random.nextDouble() * 1200 - 600,
          ),
      ];
      final index = StaticObstacleIndex(obstacles);

      for (final center in [
        at(east: 0, north: 0),
        at(east: 300, north: -200),
        at(east: -450, north: 500),
      ]) {
        const radius = 60.0;
        final byScan = obstacles
            .where((obstacle) =>
                minDistanceToPolygonMeters(center, obstacle.points) <= radius)
            .map((obstacle) => obstacle.id)
            .toSet();
        final byIndex =
            index.query(center, radius).map((obstacle) => obstacle.id).toSet();
        // 索引は上位集合。全件走査で拾えるものを落とさない。
        expect(byIndex.containsAll(byScan), isTrue);
        // かつ、実際に絞り込めている。
        expect(byIndex.length, lessThan(obstacles.length));
      }
    });

    test('空リスト・異常な半径でも壊れない', () {
      expect(StaticObstacleIndex(const []).query(at(east: 0, north: 0), 50),
          isEmpty);
      final index = StaticObstacleIndex([
        squareAt(id: 'a', east: 0, north: 0),
      ]);
      expect(index.query(at(east: 0, north: 0), double.nan), hasLength(1));
      expect(index.query(at(east: 0, north: 0), -1), hasLength(1));
      // 極端に大きい半径は索引を諦めて全件返す(判定結果は変わらない)。
      expect(index.query(at(east: 0, north: 0), 1e9), hasLength(1));
    });

    test('桜川の同梱プロファイルで、周辺の数枚まで絞り込める', () async {
      final obstacles = await PresetObstacleService(
        includeTestZones: false,
      ).loadPresets();
      expect(obstacles.length, greaterThan(200),
          reason: '前提: 岸が辺ごとの長方形へ展開され、300枚規模になること');

      final index = StaticObstacleIndex(obstacles);
      // 実際の危険区域のどこかを基準に、予測が届く程度の半径で引く。
      final anchor = obstacles.first.points.first;
      final nearby = index.query(anchor, 60);

      expect(nearby, isNotEmpty);
      expect(nearby.length, lessThan(obstacles.length ~/ 4),
          reason: '1Hz評価で全件走査を避けられること');
    });
  });
}
