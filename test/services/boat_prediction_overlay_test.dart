import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import 'package:rowing_navigator/services/boat_prediction_overlay_service.dart';
import 'package:rowing_navigator/services/channel_centerline.dart';
import 'package:rowing_navigator/types/boat_type.dart';
import 'package:rowing_navigator/utils/geo_math.dart';

const _originLatitude = 36.08;
const _originLongitude = 140.12;
const _metersPerLatitudeDegree = 111195.08;

LatLng _at({required double east, required double north}) => LatLng(
      _originLatitude + north / _metersPerLatitudeDegree,
      _originLongitude +
          east /
              (_metersPerLatitudeDegree *
                  math.cos(_originLatitude * math.pi / 180)),
    );

Boat _boat({double heading = 0, double speed = 4}) => Boat(
      boatId: 'own',
      boatType: BoatType.r_1x,
      lat: _originLatitude,
      lng: _originLongitude,
      heading: heading,
      speed: speed,
      timestamp: DateTime.utc(2026, 8, 5),
    );

/// 東へ膨らむ右カーブの中心線。
ChannelCenterline _arcCenterline({double radius = 150, double sweep = 100}) {
  final points = <LatLng>[];
  for (var degrees = 0.0; degrees <= sweep; degrees += 5) {
    final radians = degrees * math.pi / 180;
    points.add(_at(
      east: radius * (1 - math.cos(radians)),
      north: radius * math.sin(radians),
    ));
  }
  return ChannelCenterline.fromPolyline(points)!;
}

/// 折れ線の全長 [m]。
double _pathLength(List<LatLng> points) {
  var total = 0.0;
  for (var index = 1; index < points.length; index++) {
    total += distanceMeters(points[index - 1], points[index]);
  }
  return total;
}

void main() {
  group('buildBoatPredictionOverlay', () {
    test('中心線が無ければ直線1区間の2点へ縮退する', () {
      final overlay = buildBoatPredictionOverlay(
        boat: _boat(heading: 0, speed: 4),
        horizonSeconds: 10,
        stoppingDistanceMeters: 12,
        tickHalfWidthMeters: 4.5,
      );

      expect(overlay, isNotNull);
      expect(overlay!.pathPoints.length, 2);
      // 4 m/s × 10s = 40m
      expect(_pathLength(overlay.pathPoints), closeTo(40, 1));
      // 真北へ進むので、終点は始点より北にある。
      expect(
        overlay.pathPoints.last.latitude,
        greaterThan(overlay.pathPoints.first.latitude),
      );
    });

    test('中心線があれば川なりの折れ線になる', () {
      final overlay = buildBoatPredictionOverlay(
        boat: _boat(heading: 0, speed: 4),
        horizonSeconds: 10,
        stoppingDistanceMeters: 12,
        tickHalfWidthMeters: 4.5,
        centerline: _arcCenterline(),
      );

      expect(overlay, isNotNull);
      // 曲がる = 3点以上、かつ終点が直線予測より東へ寄る。
      expect(overlay!.pathPoints.length, greaterThan(2));
      expect(
        overlay.pathPoints.last.longitude,
        greaterThan(overlay.pathPoints.first.longitude),
      );
      // 折れ線でも全長は予測地平ぶんのまま(速度×時間)。
      expect(_pathLength(overlay.pathPoints), closeTo(40, 2));
    });

    test('停止距離の横棒は経路上に立ち、長さは排他領域の幅になる', () {
      final overlay = buildBoatPredictionOverlay(
        boat: _boat(heading: 0, speed: 4),
        horizonSeconds: 10,
        stoppingDistanceMeters: 12,
        tickHalfWidthMeters: 4.5,
      );

      final tick = overlay!.stoppingTick!;
      expect(tick.length, 2);
      // 半幅4.5m → 棒の全長9m
      expect(distanceMeters(tick.first, tick.last), closeTo(9, 0.2));
      // 中点が始点から停止距離ぶん進んだ位置にある。
      final middle = LatLng(
        (tick.first.latitude + tick.last.latitude) / 2,
        (tick.first.longitude + tick.last.longitude) / 2,
      );
      expect(
        distanceMeters(overlay.pathPoints.first, middle),
        closeTo(12, 0.3),
      );
    });

    test('停止距離が予測地平より先なら横棒を出さない', () {
      // 「地平に張り付いた棒 = ここで止まれる」と誤読させないこと。
      final overlay = buildBoatPredictionOverlay(
        boat: _boat(heading: 0, speed: 4),
        horizonSeconds: 10,
        stoppingDistanceMeters: 500,
        tickHalfWidthMeters: 4.5,
      );

      expect(overlay, isNotNull);
      expect(overlay!.stoppingTick, isNull);
    });

    test('停止中は経路そのものを出さない', () {
      // 短い線は「ごく手前で止まる」という別の意味に読める。
      final overlay = buildBoatPredictionOverlay(
        boat: _boat(heading: 0, speed: 0),
        horizonSeconds: 10,
        stoppingDistanceMeters: 0,
        tickHalfWidthMeters: 4.5,
      );

      expect(overlay, isNull);
    });

    test('座標が壊れていれば何も描かない', () {
      final broken = Boat(
        boatId: 'own',
        boatType: BoatType.r_1x,
        lat: double.nan,
        lng: _originLongitude,
        heading: 0,
        speed: 4,
        timestamp: DateTime.utc(2026, 8, 5),
      );

      expect(
        buildBoatPredictionOverlay(
          boat: broken,
          horizonSeconds: 10,
          stoppingDistanceMeters: 12,
          tickHalfWidthMeters: 4.5,
        ),
        isNull,
      );
    });
  });
}
