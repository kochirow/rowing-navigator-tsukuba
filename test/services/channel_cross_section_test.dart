import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/models/channel_lane.dart';
import 'package:rowing_navigator/services/channel_centerline.dart';
import 'package:rowing_navigator/services/channel_cross_section.dart';
import 'package:rowing_navigator/services/channel_lane_resolver.dart';

/// 真北へ 500m 伸びる中心線。頂点の並び順 = 北向きになる。
ChannelCenterline _northboundCenterline() =>
    ChannelCenterline.fromPolyline(const [
      LatLng(36.0000, 140.0000),
      LatLng(36.0045, 140.0000),
    ])!;

/// 経度 1e-5 度はこの緯度で約 0.9m。20m ≒ 0.000222 度。
const double _twentyMetersInLongitude = 0.000222;

ChannelLane _lane({
  required String id,
  required LaneDirection direction,
  required bool eastSide,
}) {
  final outer = eastSide
      ? 140.0 + _twentyMetersInLongitude
      : 140.0 - _twentyMetersInLongitude;
  return ChannelLane(
    id: id,
    name: id,
    direction: direction,
    centerlineId: 'centerline',
    points: [
      const LatLng(36.0000, 140.0000),
      const LatLng(36.0045, 140.0000),
      LatLng(36.0045, outer),
      LatLng(36.0000, outer),
    ],
  );
}

/// 東側 = 北向き(along)のレーン。桜川本流と同じ並び。
ChannelLaneResolver _standardResolver() => ChannelLaneResolver(
      [
        _lane(id: 'east', direction: LaneDirection.along, eastSide: true),
        _lane(id: 'west', direction: LaneDirection.against, eastSide: false),
      ],
      centerlines: {'centerline': _northboundCenterline()},
    );

/// 西側 = 北向き(along)のレーン。霞ヶ浦側と同じ並び(規則ではなく形状から
/// 左右を決めていることを確かめるための鏡像)。
ChannelLaneResolver _mirroredResolver() => ChannelLaneResolver(
      [
        _lane(id: 'west', direction: LaneDirection.along, eastSide: false),
        _lane(id: 'east', direction: LaneDirection.against, eastSide: true),
      ],
      centerlines: {'centerline': _northboundCenterline()},
    );

void main() {
  final service = ChannelCrossSectionService();
  // 中心線から東へ約9m。
  final eastOfCenter = LatLng(36.0020, 140.0 + _twentyMetersInLongitude / 2);
  final westOfCenter = LatLng(36.0020, 140.0 - _twentyMetersInLongitude / 2);

  ChannelCrossSection describe(
    LatLng position,
    double heading, {
    ChannelLaneResolver? resolver,
    bool headingIsReliable = true,
  }) =>
      ChannelCrossSectionService().describe(
        position: position,
        headingDegrees: heading,
        headingIsReliable: headingIsReliable,
        resolver: resolver ?? _standardResolver(),
      );

  test('中心線からの距離を出す', () {
    final section = describe(eastOfCenter, 0);
    expect(section.status, ChannelCrossSectionStatus.available);
    expect(section.distanceFromCenterMeters, closeTo(9, 2));
  });

  test('進行方向の右舷は、漕手から見て左(=画面の左)になる', () {
    // 地図は rowingMapBearing(進行方位+180度)で回しており、漕手は
    // 後ろ向きに座る。進行方向の右舷は漕手の左手側にある。
    final section = describe(eastOfCenter, 0); // 北向き = 頂点の並び順
    expect(section.boatSide, RowerSide.left);
    expect(section.expectedSide, RowerSide.left);
    expect(section.isInExpectedLane, isTrue);
  });

  test('向きが変われば左右も入れ替わる', () {
    // 同じ場所でも南向きなら、そこは進行方向の左舷 = 漕手の右手側。
    final section = describe(eastOfCenter, 180);
    expect(section.boatSide, RowerSide.right);
  });

  test('対向レーンにいることを見分ける', () {
    // 東側レーンは北向き(along)。そこを南向きに走れば対向レーン。
    final section = describe(eastOfCenter, 180);
    expect(section.status, ChannelCrossSectionStatus.available);
    expect(section.isInExpectedLane, isFalse);
    expect(section.expectedSide, isNot(section.boatSide));
  });

  test('自分のレーンにいれば、入るべき側と一致する', () {
    final section = describe(westOfCenter, 180); // 西側 = 南向き(against)
    expect(section.isInExpectedLane, isTrue);
    expect(section.expectedSide, section.boatSide);
  });

  test('レーンの左右は右側通行の規則ではなく、レーンの形から決める', () {
    // 同梱プロファイルでは、水域によって along レーンが中心線の
    // 左側にある(霞ヶ浦)。規則から導くと、そこで左右が反転する。
    final section =
        describe(westOfCenter, 0, resolver: _mirroredResolver()); // 北向き
    expect(section.status, ChannelCrossSectionStatus.available);
    expect(section.isInExpectedLane, isTrue);
    expect(section.boatSide, RowerSide.right);
    expect(section.expectedSide, RowerSide.right);
  });

  test('方位が信頼できないときは左右を出さないが、距離は残す', () {
    // 低速時の course-over-ground は最大90度ずれる(不変条件10)。
    // ただしデータ欠損を理由に表示ごと消さない(原則6)。
    final section = describe(eastOfCenter, 0, headingIsReliable: false);
    expect(section.status, ChannelCrossSectionStatus.distanceOnly);
    expect(section.distanceFromCenterMeters, closeTo(9, 2));
    expect(section.boatSide, isNull);
    expect(section.expectedSide, isNull);
    expect(section.isInExpectedLane, isNull);
  });

  test('レーンの外・航路情報なしは unavailable', () {
    // 桟橋や航路外ではこれが正常。警告にはしない。
    final outside = describe(const LatLng(36.0020, 140.0100), 0);
    expect(outside.status, ChannelCrossSectionStatus.unavailable);
    expect(outside.distanceFromCenterMeters, isNull);

    final noResolver = ChannelCrossSectionService().describe(
      position: eastOfCenter,
      headingDegrees: 0,
      headingIsReliable: true,
      resolver: null,
    );
    expect(noResolver.status, ChannelCrossSectionStatus.unavailable);
  });

  test('同じレーンを何度引いても結果が変わらない(側の保持が壊れていない)', () {
    final resolver = _standardResolver();
    final first = service.describe(
      position: eastOfCenter,
      headingDegrees: 0,
      headingIsReliable: true,
      resolver: resolver,
    );
    for (var i = 0; i < 5; i++) {
      final again = service.describe(
        position: eastOfCenter,
        headingDegrees: 0,
        headingIsReliable: true,
        resolver: resolver,
      );
      expect(again.boatSide, first.boatSide);
      expect(again.expectedSide, first.expectedSide);
    }
  });
}
