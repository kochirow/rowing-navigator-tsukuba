import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/config/risk_evaluator_config.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import 'package:rowing_navigator/models/channel_lane.dart';
import 'package:rowing_navigator/services/channel_lane_resolver.dart';
import 'package:rowing_navigator/services/collision_risk_evaluator_service.dart';
import 'package:rowing_navigator/services/preset_obstacle_service.dart';
import 'package:rowing_navigator/services/reverse_guidance_debouncer.dart';
import 'package:rowing_navigator/types/boat_type.dart';
import 'package:rowing_navigator/utils/winding_algorithm.dart';

LatLng _interiorPoint(ChannelLane lane) {
  final average = LatLng(
    lane.points.fold<double>(0, (sum, point) => sum + point.latitude) /
        lane.points.length,
    lane.points.fold<double>(0, (sum, point) => sum + point.longitude) /
        lane.points.length,
  );
  if (isPointInPolygon(average, lane.points)) return average;
  // 凹ポリゴンでも、先頭頂点と連続する2頂点から作る三角形のどれかには
  // 内部点がある。作図後に退化形状を早く検出できるよう明示する。
  for (var index = 1; index < lane.points.length - 1; index++) {
    final candidate = LatLng(
      (lane.points.first.latitude +
              lane.points[index].latitude +
              lane.points[index + 1].latitude) /
          3,
      (lane.points.first.longitude +
              lane.points[index].longitude +
              lane.points[index + 1].longitude) /
          3,
    );
    if (isPointInPolygon(candidate, lane.points)) return candidate;
  }
  throw StateError('lane ${lane.id} has no discoverable interior point');
}

Boat _boatAt(LatLng point, double heading) => Boat(
      boatId: 'integration-own',
      boatType: BoatType.r_1x,
      lat: point.latitude,
      lng: point.longitude,
      heading: heading % 360,
      speed: 4,
      timestamp: DateTime.utc(2026, 7, 29),
      accuracy: 5,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    '手動中心線・2レーンの実データは正しい向きだけをcompliantにする',
    () async {
      final service = PresetObstacleService(
        includeTestZones: false,
        useLocalDangerZoneSettings: false,
        useLocalFixedObstacleCalibrations: false,
      );
      final centerline = await service.loadChannelCenterline();
      final lanes = await service.loadChannelLanes();

      // #1–#4: 手引き中心線、exactly 2枚、方向、レーン内の有効な投影を確認。
      expect(service.isChannelCenterlineDerivedFromShores, isFalse);
      expect(centerline, isNotNull);
      expect(lanes, hasLength(2));
      expect(
        lanes.map((lane) => lane.direction).toSet(),
        containsAll(<LaneDirection>[
          LaneDirection.along,
          LaneDirection.against,
        ]),
      );
      final resolver = ChannelLaneResolver(lanes);
      final evaluator = CollisionRiskEvaluatorService();
      final t0 = DateTime.utc(2026, 7, 29, 12);

      for (final lane in lanes) {
        final point = _interiorPoint(lane);
        expect(resolver.resolve(point), lane.direction,
            reason: '${lane.id} must not overlap another lane');
        final frame = centerline!.project(point);
        expect(frame.isInsideCoverage, isTrue,
            reason: '${lane.id} must remain inside centerline coverage');
        final tangent = centerline.tangentBearingAt(frame.alongMeters);
        final required =
            lane.direction == LaneDirection.along ? tangent : tangent + 180;

        // #5: 規定方向の仮想航跡では逆走にしない。
        expect(
          evaluator.evaluateReverseGuidance(
            _boatAt(point, required),
            centerline,
            laneResolver: resolver,
          ),
          ReverseGuidanceOutcome.compliant,
        );
        // #6: 反対向きは判定され、6秒後に音声確定する。
        expect(
          evaluator.evaluateReverseGuidance(
            _boatAt(point, required + 180),
            centerline,
            laneResolver: resolver,
          ),
          ReverseGuidanceOutcome.reverse,
        );
        final debouncer = ReverseGuidanceDebouncer();
        expect(debouncer.update(isReverse: true, at: t0), isFalse);
        expect(
          debouncer.update(
            isReverse: true,
            at: t0.add(
              Duration(
                  milliseconds: (reverseGuidanceConfirmSeconds * 1000).round()),
            ),
          ),
          isTrue,
        );
      }
    },
    skip: '手動の channelCenterline / lane 座標を未反映。プロット完了時に外す。',
  );
}
