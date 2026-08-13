import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import 'package:rowing_navigator/services/channel_centerline.dart';
import 'package:rowing_navigator/services/observer_traffic_awareness_evaluator.dart';
import 'package:rowing_navigator/types/boat_type.dart';

void main() {
  const originLat = 36.0;
  const originLng = 140.0;

  Boat boat({
    required String id,
    required double northMeters,
    required double heading,
    required DateTime at,
    double speed = 3,
    double eastMeters = 0,
  }) =>
      Boat(
        boatId: id,
        displayName: id.toUpperCase(),
        boatType: BoatType.r_1x,
        lat: originLat + northMeters / 111320,
        lng: originLng +
            eastMeters / (111320 * math.cos(originLat * math.pi / 180)),
        heading: heading,
        speed: speed,
        timestamp: at,
        serverUpdatedAt: at,
        accuracy: 8,
      );

  ObserverTrafficEvaluation evaluate(
    ObserverTrafficAwarenessEvaluator evaluator,
    ObserverTrafficState previous,
    DateTime at,
    List<Boat> boats,
  ) =>
      evaluator.evaluate(
        boats: boats,
        evaluatedAt: at,
        previousState: previous,
      );

  test('180mで非表示の確認を開始し、150m内で3観測後に表示する', () {
    final evaluator = ObserverTrafficAwarenessEvaluator();
    final start = DateTime.utc(2026, 8, 3, 0);
    var state = ObserverTrafficState.empty;

    for (final sample in <(int, double)>[(0, 175), (1, 160), (2, 149)]) {
      final at = start.add(Duration(seconds: sample.$1));
      final result = evaluate(evaluator, state, at, [
        boat(id: 'a', northMeters: 0, heading: 0, at: at),
        boat(id: 'b', northMeters: sample.$2, heading: 180, at: at),
      ]);
      state = result.nextState;
      if (sample.$1 < 2) {
        expect(result.snapshot.groups, isEmpty);
      } else {
        expect(result.snapshot.groups, hasLength(1));
        expect(result.snapshot.groups.single.boatIds, ['a', 'b']);
      }
    }
  });

  test('151mでは表示せず、149mの新しい観測で確定する', () {
    final evaluator = ObserverTrafficAwarenessEvaluator();
    final start = DateTime.utc(2026, 8, 3, 0);
    var state = ObserverTrafficState.empty;

    for (final sample in <(int, double)>[(0, 170), (1, 151), (2, 149)]) {
      final at = start.add(Duration(seconds: sample.$1));
      final result = evaluate(evaluator, state, at, [
        boat(id: 'a', northMeters: 0, heading: 0, at: at),
        boat(id: 'b', northMeters: sample.$2, heading: 180, at: at),
      ]);
      state = result.nextState;
      if (sample.$1 < 2) expect(result.snapshot.groups, isEmpty);
      if (sample.$1 == 2) expect(result.snapshot.groups, hasLength(1));
    }
  });

  test('同方向の並走と停止艇は早期注意にしない', () {
    final evaluator = ObserverTrafficAwarenessEvaluator();
    final at = DateTime.utc(2026, 8, 3, 0);
    final parallel = evaluate(evaluator, ObserverTrafficState.empty, at, [
      boat(id: 'a', northMeters: 0, heading: 0, at: at),
      boat(id: 'b', northMeters: 100, heading: 0, at: at),
    ]);
    expect(parallel.snapshot.groups, isEmpty);

    final stopped = evaluate(evaluator, ObserverTrafficState.empty, at, [
      boat(id: 'a', northMeters: 0, heading: 0, at: at),
      boat(id: 'b', northMeters: 100, heading: 180, at: at, speed: 0.2),
    ]);
    expect(stopped.snapshot.groups, isEmpty);
  });

  test('A-BとB-Cだけを3艇の1グループに集約する', () {
    final evaluator = ObserverTrafficAwarenessEvaluator();
    final start = DateTime.utc(2026, 8, 3, 0);
    var state = ObserverTrafficState.empty;
    ObserverTrafficEvaluation? result;
    for (var second = 0; second <= 2; second++) {
      final at = start.add(Duration(seconds: second));
      result = evaluate(evaluator, state, at, [
        boat(id: 'a', northMeters: 0, heading: 0, at: at),
        boat(id: 'b', northMeters: 80, heading: 180, at: at),
        // Bは南向き、A/Cは北向き。Bを挟む2辺だけが接近する。
        boat(id: 'c', northMeters: -65, heading: 0, at: at),
      ]);
      state = result.nextState;
    }
    expect(result!.snapshot.groups, hasLength(1));
    expect(result.snapshot.groups.single.boatIds, ['a', 'b', 'c']);
    expect(result.snapshot.groups.single.pairs.map((pair) => pair.pairId),
        containsAll(['a|b', 'b|c']));
    expect(result.snapshot.groups.single.pairs.map((pair) => pair.pairId),
        isNot(contains('a|c')));
  });

  test('古い位置から新しい早期注意を作らない', () {
    final evaluator = ObserverTrafficAwarenessEvaluator();
    final now = DateTime.utc(2026, 8, 3, 0, 0, 10);
    final old = now.subtract(const Duration(seconds: 7));
    final result = evaluate(evaluator, ObserverTrafficState.empty, now, [
      boat(id: 'a', northMeters: 0, heading: 0, at: old),
      boat(id: 'b', northMeters: 100, heading: 180, at: old),
    ]);
    expect(result.snapshot.groups, isEmpty);
    expect(result.snapshot.dataIssueCount, greaterThan(0));
  });

  test('中心線上の逆走は6秒連続してから赤バナー対象にする', () {
    final evaluator = ObserverTrafficAwarenessEvaluator();
    final centerline = ChannelCenterline.fromPolyline([
      const LatLng(originLat, originLng),
      LatLng(originLat + 400 / 111320, originLng),
    ])!;
    final start = DateTime.utc(2026, 8, 3, 0);
    var state = ObserverTrafficState.empty;

    for (var second = 0; second <= 6; second++) {
      final at = start.add(Duration(seconds: second));
      final result = evaluator.evaluate(
        boats: [
          boat(
            id: 'reverse',
            northMeters: 100,
            eastMeters: 15,
            heading: 180,
            at: at,
          ),
        ],
        evaluatedAt: at,
        previousState: state,
        channelCenterline: centerline,
      );
      state = result.nextState;
      expect(
        result.snapshot.reverseBoats.map((boat) => boat.boatId),
        second < 6 ? isEmpty : ['reverse'],
      );
    }
  });
}
