import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/models/channel_lane.dart';
import 'package:rowing_navigator/services/channel_centerline.dart';
import 'package:rowing_navigator/services/channel_lane_resolver.dart';

LatLng point(double lat, double lng) => LatLng(lat, lng);

ChannelLane lane({
  required String id,
  required LaneDirection direction,
  String? centerlineId,
  required List<LatLng> points,
}) =>
    ChannelLane(
      id: id,
      name: id,
      direction: direction,
      centerlineId: centerlineId,
      points: points,
    );

void main() {
  group('ChannelLane.fromJson', () {
    final valid = <String, dynamic>{
      'id': 'lane_along',
      'name': '往路',
      'kind': 'lane',
      'direction': 'along',
      'centerlineId': 'sakuragawa_axis',
      'points': [
        {'lat': 36.0, 'lng': 140.0},
        {'lat': 36.0, 'lng': 140.01},
        {'lat': 36.01, 'lng': 140.01},
      ],
    };

    test('有効な向き付きレーンを不変の型として読む', () {
      final parsed = ChannelLane.fromJson(valid);

      expect(parsed.direction, LaneDirection.along);
      expect(parsed.centerlineId, 'sakuragawa_axis');
      expect(parsed.points, hasLength(3));
      expect(() => parsed.points.add(point(36.02, 140.02)),
          throwsUnsupportedError);
    });

    test('direction の欠落・不正値・不正座標を拒否する', () {
      expect(
        () => ChannelLane.fromJson({...valid}..remove('direction')),
        throwsFormatException,
      );
      expect(
        () => ChannelLane.fromJson({...valid, 'direction': 'downstream'}),
        throwsFormatException,
      );
      expect(
        () => ChannelLane.fromJson({
          ...valid,
          'points': [
            {'lat': 36.0, 'lng': 140.0},
            {'lat': 91.0, 'lng': 140.01},
            {'lat': 36.01, 'lng': 140.01},
          ],
        }),
        throwsFormatException,
      );
    });
  });

  group('ChannelLaneResolver', () {
    final along = lane(
      id: 'lane_along',
      direction: LaneDirection.along,
      points: [point(0, 0), point(0, 10), point(10, 10), point(10, 0)],
    );
    final against = lane(
      id: 'lane_against',
      direction: LaneDirection.against,
      points: [point(0, 12), point(0, 20), point(10, 20), point(10, 12)],
    );

    test('内包したレーンの規定進行方向を返す', () {
      final resolver = ChannelLaneResolver([along, against]);

      expect(resolver.hasCompleteLaneSet, isTrue);
      expect(resolver.resolve(point(5, 5)), LaneDirection.along);
      expect(resolver.resolve(point(5, 15)), LaneDirection.against);
    });

    test('レーン間の隙間では判定しない', () {
      final resolver = ChannelLaneResolver([along, against]);

      expect(resolver.resolve(point(5, 11)), isNull);
    });

    test('重なったレーンでは判定しない', () {
      final overlap = lane(
        id: 'lane_overlap',
        direction: LaneDirection.against,
        points: [point(0, 5), point(0, 15), point(10, 15), point(10, 5)],
      );

      expect(
          ChannelLaneResolver([along, overlap]).resolve(point(5, 7)), isNull);
    });

    test('1枚だけは既存のcross符号方式へ縮退させる', () {
      expect(ChannelLaneResolver([along]).hasCompleteLaneSet, isFalse);
    });

    test('現在レーンに明示された複数中心線から正しい1本を選ぶ', () {
      final sakuragawa = ChannelCenterline.fromPolyline([
        point(0, 5),
        point(10, 5),
      ])!;
      final kasumigaura = ChannelCenterline.fromPolyline([
        point(0, 15),
        point(10, 15),
      ])!;
      final linkedAlong = lane(
        id: 'sakuragawa_outbound',
        direction: LaneDirection.along,
        centerlineId: 'sakuragawa_axis',
        points: along.points,
      );
      final linkedAgainst = lane(
        id: 'kasumigaura_return',
        direction: LaneDirection.against,
        centerlineId: 'kasumigaura_axis',
        points: against.points,
      );
      final resolver = ChannelLaneResolver(
        [linkedAlong, linkedAgainst],
        centerlines: {
          'sakuragawa_axis': sakuragawa,
          'kasumigaura_axis': kasumigaura,
        },
      );

      expect(resolver.hasLinkedCenterlines, isTrue);
      expect(resolver.centerlineFor(point(5, 5)), same(sakuragawa));
      expect(resolver.centerlineFor(point(5, 15)), same(kasumigaura));
      expect(resolver.centerlineFor(point(5, 11)), isNull);
    });

    test('一部だけの中心線紐付けでは旧逆走区域を止めない', () {
      final centerline = ChannelCenterline.fromPolyline([
        point(0, 5),
        point(10, 5),
      ])!;
      final partiallyLinked = ChannelLaneResolver(
        [
          lane(
            id: 'linked',
            direction: LaneDirection.along,
            centerlineId: 'sakuragawa_axis',
            points: along.points,
          ),
          against,
        ],
        centerlines: {'sakuragawa_axis': centerline},
      );

      expect(partiallyLinked.hasLinkedCenterlines, isFalse);
    });
  });
}
