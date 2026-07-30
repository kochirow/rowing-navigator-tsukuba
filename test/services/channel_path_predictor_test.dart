import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import 'package:rowing_navigator/services/channel_centerline.dart';
import 'package:rowing_navigator/services/channel_path_predictor.dart';
import 'package:rowing_navigator/types/boat_type.dart';
import 'package:rowing_navigator/utils/geo_math.dart';

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

Boat boatAt(LatLng position, {required double heading, double speed = 4}) =>
    Boat(
      boatId: 'own',
      boatType: BoatType.r_1x,
      lat: position.latitude,
      lng: position.longitude,
      heading: heading,
      speed: speed,
      timestamp: DateTime.utc(2026, 7, 25),
    );

/// 半径 [radius] の円弧(東へ膨らむ右カーブ)を中心線として作る。
ChannelCenterline arcCenterline({double radius = 150, double sweep = 100}) {
  final points = <LatLng>[];
  for (var degrees = 0.0; degrees <= sweep; degrees += 5) {
    final radians = degrees * math.pi / 180;
    points.add(at(
      east: radius * (1 - math.cos(radians)),
      north: radius * math.sin(radians),
    ));
  }
  return ChannelCenterline.fromPolyline(points)!;
}

/// 折れ線予測の頂点列(各区間の始点 + 最終区間の終点)。
List<LatLng> polylineOf(List<PredictedMotionSegment> segments) => [
      for (final segment in segments) segment.origin,
      computeOffset(
        segments.last.origin,
        segments.last.lengthMeters,
        segments.last.headingDegrees,
      ),
    ];

void main() {
  const predictor = ChannelPathPredictor();

  group('ChannelPathPredictor', () {
    test('中心線が無ければ従来どおり等速直線1区間を返す', () {
      final segments = predictor.predict(
        boat: boatAt(at(east: 0, north: 0), heading: 0),
        horizonSeconds: 10,
      );

      expect(segments, hasLength(1));
      expect(segments.single.headingDegrees, closeTo(0, 1e-9));
      expect(segments.single.durationSeconds, 10);
      expect(segments.single.curvatureMarginMeters, 0);
      expect(segments.single.lengthMeters, closeTo(40, 0.01));
    });

    test('停止中は直線1区間へ縮退する', () {
      final segments = predictor.predict(
        boat: boatAt(at(east: 0, north: 0), heading: 0, speed: 0),
        horizonSeconds: 10,
        centerline: arcCenterline(),
      );
      expect(segments, hasLength(1));
    });

    test('川なりに進む艇の予測は中心線に沿って曲がる', () {
      final centerline = arcCenterline();
      // 中心線上・接線方向へ進む艇。
      final start = centerline.pointAt(20);
      final boat = boatAt(start, heading: centerline.tangentBearingAt(20));

      final segments = predictor.predict(
        boat: boat,
        horizonSeconds: 10,
        centerline: centerline,
      );

      expect(segments.length, greaterThan(1));

      // 予測終点は中心線上に留まる(cross ≒ 0)。
      final last = segments.last;
      final end = computeOffset(
        last.origin,
        last.lengthMeters,
        last.headingDegrees,
      );
      final endFrame = centerline.project(end);
      expect(endFrame.crossMeters.abs(), lessThan(2.0));

      // 同じ条件の直線予測は、カーブの内側へ大きく外れる。
      final straightEnd = computeOffset(start, boat.speed * 10, boat.heading);
      final straightFrame = centerline.project(straightEnd);
      expect(straightFrame.crossMeters.abs(), greaterThan(4.0));

      // 区間の合計時間と距離は予測期間と一致する。
      final totalDuration = segments.fold<double>(
        0,
        (sum, segment) => sum + segment.durationSeconds,
      );
      expect(totalDuration, closeTo(10, 1e-6));
      final totalLength = segments.fold<double>(
        0,
        (sum, segment) => sum + segment.lengthMeters,
      );
      expect(totalLength, closeTo(40, 1.0));
    });

    test('岸へ向かう艇は中心線から離れる予測になる(警告漏れを作らない)', () {
      final centerline = arcCenterline();
      final start = centerline.toLatLng(alongMeters: 20, crossMeters: 0);
      // 接線から45度、右(岸側)へ向ける。
      final boat = boatAt(
        start,
        heading: centerline.tangentBearingAt(20) + 45,
      );

      final segments = predictor.predict(
        boat: boat,
        horizonSeconds: 10,
        centerline: centerline,
      );

      final last = segments.last;
      final end = computeOffset(
        last.origin,
        last.lengthMeters,
        last.headingDegrees,
      );
      final endFrame = centerline.project(end);
      // 40m進むうち、横方向成分は 40·sin45° ≒ 28m。
      expect(endFrame.crossMeters, greaterThan(20));
    });

    test('中心線の外側にいる艇は直線予測へ戻す', () {
      final centerline = arcCenterline();
      // 中心線から200m離れた点(maxChannelProjectionOffsetMeters を超える)。
      final segments = predictor.predict(
        boat: boatAt(at(east: 400, north: 0), heading: 0),
        horizonSeconds: 10,
        centerline: centerline,
      );
      expect(segments, hasLength(1));
    });

    test('川を横断する向き(接線+90)では直線予測へ戻す', () {
      final centerline = arcCenterline();
      final start = centerline.pointAt(80);
      final boat = boatAt(
        start,
        heading: centerline.tangentBearingAt(80) + 90,
      );

      final segments = predictor.predict(
        boat: boat,
        horizonSeconds: 10,
        centerline: centerline,
      );
      expect(segments, hasLength(1));
    });

    test('川を逆行する向き(接線+180)は中心線に沿って曲がる', () {
      // 桜川は往復コース。中心線の向きは岸基準線の並び順で一意に決まるため、
      // 行きか帰りのどちらかは必ず along 速度が負になる。逆行を直線予測へ
      // 落とすと、航行時間の約半分でカーブの外岸へ膨らんだ予測になる(原則4)。
      final centerline = arcCenterline();
      final start = centerline.pointAt(80);
      final boat = boatAt(
        start,
        heading: centerline.tangentBearingAt(80) + 180,
      );

      final segments = predictor.predict(
        boat: boat,
        horizonSeconds: 10,
        centerline: centerline,
      );

      expect(segments.length, greaterThan(1));

      // 予測終点は中心線上に留まる(cross ≒ 0)。
      final last = segments.last;
      final end = computeOffset(
        last.origin,
        last.lengthMeters,
        last.headingDegrees,
      );
      final endFrame = centerline.project(end);
      expect(endFrame.crossMeters.abs(), lessThan(2.0));
      // 40m ぶん中心線を遡る(along 80 → 40)。
      expect(endFrame.alongMeters, closeTo(40, 2.0));

      // 同じ条件の直線予測は、カーブの内側へ大きく外れる。
      final straightEnd = computeOffset(start, boat.speed * 10, boat.heading);
      expect(
          centerline.project(straightEnd).crossMeters.abs(), greaterThan(4.0));

      final totalDuration = segments.fold<double>(
        0,
        (sum, segment) => sum + segment.durationSeconds,
      );
      expect(totalDuration, closeTo(10, 1e-6));
    });

    test('逆向きの予測点は正方向のときと対称になる', () {
      final centerline = arcCenterline();
      // 同じ区間(along 40〜80)を、正方向と逆方向からそれぞれ予測する。
      final forward = predictor.predict(
        boat: boatAt(
          centerline.pointAt(40),
          heading: centerline.tangentBearingAt(40),
        ),
        horizonSeconds: 10,
        centerline: centerline,
      );
      final backward = predictor.predict(
        boat: boatAt(
          centerline.pointAt(80),
          heading: centerline.tangentBearingAt(80) + 180,
        ),
        horizonSeconds: 10,
        centerline: centerline,
      );

      expect(backward.length, forward.length);

      final forwardPoints = polylineOf(forward);
      final backwardPoints = polylineOf(backward);
      expect(backwardPoints, hasLength(forwardPoints.length));
      for (var index = 0; index < forwardPoints.length; index++) {
        final mirrored = backwardPoints[backwardPoints.length - 1 - index];
        expect(
          distanceMeters(forwardPoints[index], mirrored),
          lessThan(0.5),
          reason: '$index 番目の予測点が逆向きのときと一致しない',
        );
      }

      // 進行方位も互いに180度ずれた対応関係になる。
      for (var index = 0; index < forward.length; index++) {
        final mirrored = backward[backward.length - 1 - index];
        final delta =
            ((mirrored.headingDegrees - forward[index].headingDegrees) % 360 +
                    360) %
                360;
        expect(delta, closeTo(180, 1.0), reason: '$index 番目の方位');
      }
    });

    test('逆行が中心線の始端を割っても、予測の長さと時間を失わない', () {
      // 逆行を許容したことで along < 0(中心線の始端超え)が初めて到達可能に
      // なった。ここで区間を落とすと予測地平が黙って縮み、その先の危険が
      // 見えなくなる(原則6: データ欠損は安全の根拠にならない)。
      final centerline = arcCenterline();
      final segments = predictor.predict(
        boat: boatAt(
          centerline.pointAt(10),
          heading: centerline.tangentBearingAt(10) + 180,
        ),
        horizonSeconds: 10,
        centerline: centerline,
      );

      expect(segments, isNotEmpty);
      final totalDuration = segments.fold<double>(
        0,
        (sum, segment) => sum + segment.durationSeconds,
      );
      expect(totalDuration, closeTo(10, 1e-6));
      final totalLength = segments.fold<double>(
        0,
        (sum, segment) => sum + segment.lengthMeters,
      );
      expect(totalLength, closeTo(40, 1.0));
    });

    test('曲率マージンは有界で、直線では0になる', () {
      final straight = ChannelCenterline.fromPolyline([
        at(east: 0, north: 0),
        at(east: 0, north: 400),
      ])!;
      final segments = predictor.predict(
        boat: boatAt(at(east: 0, north: 20), heading: 0),
        horizonSeconds: 10,
        centerline: straight,
      );
      for (final segment in segments) {
        expect(segment.curvatureMarginMeters, closeTo(0, 0.05));
      }

      // 急カーブでも上限(3m)を超えない。
      final tight = arcCenterline(radius: 40, sweep: 170);
      final tightSegments = predictor.predict(
        boat: boatAt(
          tight.pointAt(10),
          heading: tight.tangentBearingAt(10),
        ),
        horizonSeconds: 10,
        centerline: tight,
      );
      for (final segment in tightSegments) {
        expect(segment.curvatureMarginMeters, lessThanOrEqualTo(3.0));
        expect(segment.curvatureMarginMeters, greaterThanOrEqualTo(0));
      }
    });
  });
}
