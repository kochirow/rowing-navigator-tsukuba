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

/// 帯の左右の辺を、頂点列から取り出す。
/// [outline] は「左辺を順に + 右辺を逆順に」なので、前半と後半に割れる。
(List<LatLng>, List<LatLng>) _sides(List<LatLng> outline) {
  final half = outline.length ~/ 2;
  return (outline.sublist(0, half), outline.sublist(half).reversed.toList());
}

/// 位置 [index] における帯の幅 [m]。
double _widthAt(List<LatLng> outline, int index) {
  final (left, right) = _sides(outline);
  return distanceMeters(left[index], right[index]);
}

void main() {
  group('buildBoatPredictionBeam', () {
    test('帯の長さは停止距離に一致する', () {
      final beam = buildBoatPredictionBeam(
        boat: _boat(heading: 0, speed: 4),
        stoppingDistanceMeters: 28,
        halfWidthMeters: 4.5,
      )!;

      // 「いま止まろうとしても、ここまでは行く」が図の唯一の意味なので、
      // 長さが停止距離からずれてはいけない。
      expect(beam.lengthMeters, closeTo(28, 0.5));
    });

    test('根元は排他領域の幅、先端は絞られる', () {
      final beam = buildBoatPredictionBeam(
        boat: _boat(heading: 0, speed: 4),
        stoppingDistanceMeters: 28,
        halfWidthMeters: 4.5,
      )!;

      final rootWidth = _widthAt(beam.outline, 0);
      final tipWidth = _widthAt(beam.outline, beam.outline.length ~/ 2 - 1);
      // 根元 = 半幅4.5m の両側で9m。艇の幅と一致するので帯が艇から生えて見える。
      expect(rootWidth, closeTo(9, 0.2));
      // 先細りが方向を伝える。先端が根元より明確に細いこと。
      expect(tipWidth, lessThan(rootWidth * 0.5));
      // ただし0にはしない(先端が消えると長さが読めない)。
      expect(tipWidth, greaterThan(1.0));
    });

    test('低速でも幅が長さを追い越さない(器に見えない)', () {
      // 実機の 9:28/500m ≒ 0.88m/s。停止距離は約6mしかないのに、根元を
      // 排他領域の幅(9m)で固定すると幅>長さになり、先細りの帯ではなく
      // すぼまった器に見えて方向が読めない。
      final beam = buildBoatPredictionBeam(
        boat: _boat(heading: 0, speed: 0.88),
        stoppingDistanceMeters: 6.1,
        halfWidthMeters: 4.5,
      )!;

      final rootWidth = _widthAt(beam.outline, 0);
      expect(
        beam.lengthMeters / rootWidth,
        greaterThanOrEqualTo(2.4),
        reason: '低速で帯が器に見える縦横比になっている',
      );
    });

    test('通常の漕行速度では根元が艇の幅のまま', () {
      // 4m/s の 1x は停止距離27.8m。27.8/2.5 = 11.1m > 9m なので、
      // 縦横比の頭打ちには掛からない。**効くのは低速のときだけ。**
      final beam = buildBoatPredictionBeam(
        boat: _boat(heading: 0, speed: 4),
        stoppingDistanceMeters: 27.8,
        halfWidthMeters: 4.5,
      )!;

      expect(_widthAt(beam.outline, 0), closeTo(9, 0.2));
    });

    test('幅は根元から先端へ単調に細くなる', () {
      final beam = buildBoatPredictionBeam(
        boat: _boat(heading: 0, speed: 4),
        stoppingDistanceMeters: 28,
        halfWidthMeters: 4.5,
      )!;

      final half = beam.outline.length ~/ 2;
      var previous = double.infinity;
      for (var index = 0; index < half; index++) {
        final width = _widthAt(beam.outline, index);
        expect(width, lessThanOrEqualTo(previous + 1e-6),
            reason: '$index 番目で帯が太くなっている');
        previous = width;
      }
    });

    test('中心線があれば川なりに曲がる', () {
      final straight = buildBoatPredictionBeam(
        boat: _boat(heading: 0, speed: 4),
        stoppingDistanceMeters: 28,
        halfWidthMeters: 4.5,
      )!;
      final curved = buildBoatPredictionBeam(
        boat: _boat(heading: 0, speed: 4),
        stoppingDistanceMeters: 28,
        halfWidthMeters: 4.5,
        centerline: _arcCenterline(),
      )!;

      final (straightLeft, _) = _sides(straight.outline);
      final (curvedLeft, _) = _sides(curved.outline);
      // 右カーブなので、曲がったほうが先端が東へ寄る。
      expect(
        curvedLeft.last.longitude,
        greaterThan(straightLeft.last.longitude),
      );
      // 曲がっても長さは停止距離のまま。
      expect(curved.lengthMeters, closeTo(28, 1));
    });

    test('停止中は帯を出さない', () {
      // 速度0では「行ってしまう先」が存在しない。艇印と重なる短い帯は
      // 団子に見えるだけで、何も伝えない。
      expect(
        buildBoatPredictionBeam(
          boat: _boat(heading: 0, speed: 0),
          stoppingDistanceMeters: 0,
          halfWidthMeters: 4.5,
        ),
        isNull,
      );
    });

    test('極低速で停止距離が数mなら帯を出さない', () {
      expect(
        buildBoatPredictionBeam(
          boat: _boat(heading: 0, speed: 0.3),
          stoppingDistanceMeters: 2.0,
          halfWidthMeters: 4.5,
        ),
        isNull,
      );
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
        buildBoatPredictionBeam(
          boat: broken,
          stoppingDistanceMeters: 28,
          halfWidthMeters: 4.5,
        ),
        isNull,
      );
    });
  });
}
