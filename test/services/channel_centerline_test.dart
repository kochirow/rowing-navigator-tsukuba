import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/services/channel_centerline.dart';
import 'package:rowing_navigator/services/preset_obstacle_service.dart';
import 'package:rowing_navigator/utils/geo_math.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ChannelCenterline', () {
    test('頂点が足りない・短すぎる折れ線は中心線にしない', () {
      expect(ChannelCenterline.fromPolyline(const []), isNull);
      expect(
        ChannelCenterline.fromPolyline([at(east: 0, north: 0)]),
        isNull,
      );
      // 全長10mでは中心線として使わない(最低50m)。
      expect(
        ChannelCenterline.fromPolyline([
          at(east: 0, north: 0),
          at(east: 0, north: 10),
        ]),
        isNull,
      );
    });

    test('直線区間では along/cross が素直な直交座標になる', () {
      final centerline = ChannelCenterline.fromPolyline([
        at(east: 0, north: 0),
        at(east: 0, north: 200),
      ])!;

      expect(centerline.lengthMeters, closeTo(200, 1));
      expect(centerline.tangentBearingAt(50), closeTo(0, 0.5));

      // 北へ80m進み、東へ10mずれた点。北向き進行の右手は東なので cross は正。
      final frame = centerline.project(at(east: 10, north: 80));
      expect(frame.alongMeters, closeTo(80, 1));
      expect(frame.crossMeters, closeTo(10, 0.5));
      expect(frame.isInsideCoverage, isTrue);

      final west = centerline.project(at(east: -10, north: 80));
      expect(west.crossMeters, closeTo(-10, 0.5));
    });

    test('曲線座標と地理座標を往復しても位置がずれない', () {
      final centerline = ChannelCenterline.fromPolyline([
        at(east: 0, north: 0),
        at(east: 60, north: 100),
        at(east: 160, north: 140),
        at(east: 260, north: 120),
      ])!;

      for (final along in [10.0, 75.0, 150.0, 220.0]) {
        for (final cross in [-15.0, 0.0, 12.0]) {
          final point =
              centerline.toLatLng(alongMeters: along, crossMeters: cross);
          final frame = centerline.project(point);
          expect(frame.alongMeters, closeTo(along, 2.5),
              reason: 'along=$along cross=$cross');
          expect(frame.crossMeters, closeTo(cross, 1.0),
              reason: 'along=$along cross=$cross');
        }
      }
    });

    test('中心線の端点より外側は範囲外として報告する', () {
      final centerline = ChannelCenterline.fromPolyline([
        at(east: 0, north: 0),
        at(east: 0, north: 200),
      ])!;

      expect(centerline.project(at(east: 0, north: -50)).isInsideCoverage,
          isFalse);
      expect(centerline.project(at(east: 0, north: 260)).isInsideCoverage,
          isFalse);
      expect(
          centerline.project(at(east: 5, north: 100)).isInsideCoverage, isTrue);
    });

    test('左右の岸から中心線を推定し、川幅の中央を通す', () {
      // 東西へ30m離れた2本の平行な岸を、同じ向きで与える。
      final north = <LatLng>[];
      final south = <LatLng>[];
      for (var index = 0; index <= 10; index++) {
        final along = index * 30.0;
        north.add(at(east: -25, north: along));
        south.add(at(east: 25, north: along));
      }

      final centerline = ChannelCenterline.fromShorelines(
        firstShore: north,
        secondShore: south,
      );

      expect(centerline, isNotNull);
      final frame = centerline!.project(at(east: 0, north: 150));
      expect(frame.crossMeters.abs(), lessThan(2));
      expect(centerline.tangentBearingAt(150), closeTo(0, 5));
    });

    test('川幅が想定外の区間しかない場合は中心線を作らない', () {
      // 500m離れた2本は同じ川の両岸ではない。
      final first = <LatLng>[];
      final second = <LatLng>[];
      for (var index = 0; index <= 10; index++) {
        final along = index * 30.0;
        first.add(at(east: 0, north: along));
        second.add(at(east: 500, north: along));
      }

      expect(
        ChannelCenterline.fromShorelines(
          firstShore: first,
          secondShore: second,
        ),
        isNull,
      );
    });

    test('同梱プリセットから霞ヶ浦・桜川河口・桜川上流の明示中心線を読む', () async {
      final service = PresetObstacleService();
      final centerlines = await service.loadChannelCenterlines();

      expect(service.isChannelCenterlineDerivedFromShores, isFalse);
      expect(centerlines, hasLength(3));
      expect(
        centerlines.keys,
        containsAll(<String>[
          'centerline_kasumikagaura',
          'centerline_sakuragawa_estuary',
          'centerline_sakuragawa_upstream',
        ]),
      );
      // 複数中心線から適当な1本を旧フォールバックへ渡してはいけない。
      expect(await service.loadChannelCenterline(), isNull);

      for (final centerline in centerlines.values) {
        expect(centerline.lengthMeters, greaterThan(500));
        expect(centerline.pointCount, greaterThanOrEqualTo(6));

        // 中心線上の点は、当然ながら cross ≒ 0 に投影される。
        final middle = centerline.pointAt(centerline.lengthMeters / 2);
        final frame = centerline.project(middle);
        expect(frame.crossMeters.abs(), lessThan(1));
        expect(frame.isInsideCoverage, isTrue);

        final right = centerline.toLatLng(
          alongMeters: frame.alongMeters,
          crossMeters: 15,
        );
        expect(distanceMeters(middle, right), closeTo(15, 1));
      }
    });
  });
}
