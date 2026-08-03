import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/config/ashore_config.dart';
import 'package:rowing_navigator/services/ashore_detector.dart';

const _earthRadiusMeters = 6378137.0;
const _degreesToRadians = math.pi / 180;
const _origin = LatLng(36.077, 140.193);

LatLng _offset({double north = 0, double east = 0}) => LatLng(
      _origin.latitude + north / _earthRadiusMeters / _degreesToRadians,
      _origin.longitude +
          east /
              (_earthRadiusMeters *
                  math.cos(_origin.latitude * _degreesToRadians)) /
              _degreesToRadians,
    );

// 中心から南北・東西40mの、確実な陸上エリアとして使うテスト矩形。
final _ashoreArea = <List<LatLng>>[
  [
    _offset(north: -40, east: -40),
    _offset(north: -40, east: 40),
    _offset(north: 40, east: 40),
    _offset(north: 40, east: -40)
  ],
];
final _t0 = DateTime.utc(2026, 7, 28, 6);

AshoreObservation _observation(
  LatLng position, {
  int seconds = 0,
  double? accuracy = 5,
  bool usable = true,
}) =>
    AshoreObservation(
      position: position,
      at: _t0.add(Duration(seconds: seconds)),
      accuracyMeters: accuracy,
      gpsQualityUsable: usable,
    );

AshoreState _feed(AshoreDetector detector, LatLng point, int seconds) {
  late AshoreState state;
  for (var second = 0; second <= seconds; second++) {
    state = detector.update(_observation(point, seconds: second));
  }
  return state;
}

void main() {
  group('AshoreDetector: 明示陸上エリア', () {
    test('エリアが空なら一度も陸上と判定しない（不変条件13）', () {
      final detector = AshoreDetector(ashoreAreas: const []);
      final state = detector.update(_observation(_origin));

      expect(detector.areaCount, 0);
      expect(state.isAshore, isFalse);
      expect(state.reason, AshoreDecisionReason.ashoreAreasUnavailable);
      expect(state.landSideDistanceMeters, isNull);
    });

    test('水上の測位では音を止めず、境界距離は負になる', () {
      final state = AshoreDetector(ashoreAreas: _ashoreArea)
          .update(_observation(_offset(east: 80)));

      expect(state.isAshore, isFalse);
      expect(state.reason, AshoreDecisionReason.onWater);
      expect(state.landSideDistanceMeters, lessThan(0));
    });

    test('陸上エリア内でも実効マージン未満では確定しない', () {
      final state = AshoreDetector(ashoreAreas: _ashoreArea)
          .update(_observation(_offset(east: 31))); // 境界から約9m

      expect(state.isAshore, isFalse);
      expect(state.reason, AshoreDecisionReason.insideMargin);
      expect(state.landSideDistanceMeters, closeTo(9, 0.5));
    });

    test('30秒の継続と精度マージンを満たして初めて陸上を確定する', () {
      final detector = AshoreDetector(ashoreAreas: _ashoreArea);
      final initial = detector.update(_observation(_origin));
      final confirmed =
          _feed(detector, _origin, ashoreConfirmationDuration.inSeconds);

      expect(initial.reason, AshoreDecisionReason.pendingConfirmation);
      expect(confirmed.isAshore, isTrue);
      expect(confirmed.reason, AshoreDecisionReason.ashoreConfirmed);
      expect(confirmed.landSideDistanceMeters,
          greaterThan(ashoreLandSideMarginMeters));
    });

    test('水上の1測位で即座に音を戻し、手動解除も解除する', () {
      final detector = AshoreDetector(ashoreAreas: _ashoreArea);
      _feed(detector, _origin, ashoreConfirmationDuration.inSeconds);
      detector.overrideToWater();
      final state =
          detector.update(_observation(_offset(east: 80), seconds: 31));

      expect(state.isAshore, isFalse);
      expect(state.reason, AshoreDecisionReason.onWater);
    });

    test('GPS品質またはaccuracyが不明なら、陸上エリア内でも音を止めない', () {
      final detector = AshoreDetector(ashoreAreas: _ashoreArea);
      final poorQuality = detector.update(_observation(_origin, usable: false));
      final unknownAccuracy = AshoreDetector(ashoreAreas: _ashoreArea)
          .update(_observation(_origin, accuracy: null));

      expect(poorQuality.reason, AshoreDecisionReason.gpsNotUsable);
      expect(unknownAccuracy.reason, AshoreDecisionReason.accuracyUnknown);
      expect(poorQuality.isAshore, isFalse);
      expect(unknownAccuracy.isAshore, isFalse);
    });

    test('航路・廃止済みの練習水域を渡す入口が無く、陸上エリアだけが根拠になる', () {
      final detector = AshoreDetector(ashoreAreas: _ashoreArea);
      expect(detector.areaCount, 1);
      // Constructor が受け取るのは ashoreAreas だけ。危険区域・航路を
      // 誤って音の抑制根拠にできないことをAPI境界で固定する。
    });

    test('重ねて描いた2枚の継ぎ目でも、和集合の奥なら陸上を確定する', () {
      // 艇庫前と桟橋を別オブジェクトで描き、10m重ねた想定。
      // 継ぎ目付近は各エリアの縁から数mしかないが、和集合の外周からは
      // 30m以上奥にある。ここで確定しないと、分割して描いた瞬間に
      // 継ぎ目沿いだけ音が止まらなくなる。
      final detector = AshoreDetector(ashoreAreas: [
        [
          _offset(north: -40, east: -80),
          _offset(north: -40, east: 5),
          _offset(north: 40, east: 5),
          _offset(north: 40, east: -80),
        ],
        [
          _offset(north: -40, east: -5),
          _offset(north: -40, east: 80),
          _offset(north: 40, east: 80),
          _offset(north: 40, east: -5),
        ],
      ]);

      final state = _feed(detector, _origin, 31);

      expect(state.isAshore, isTrue);
      expect(state.reason, AshoreDecisionReason.ashoreConfirmed);
      // 継ぎ目(±5m)ではなく、和集合の南北の外周(40m)までを測る。
      expect(state.landSideDistanceMeters, greaterThan(30));
    });

    test('重なりのない2枚では、自分がいるエリアの外周までを測る', () {
      // 離れた2枚。もう一方の存在で距離が縮んではいけない。
      final detector = AshoreDetector(ashoreAreas: [
        _ashoreArea.first,
        [
          _offset(north: -40, east: 200),
          _offset(north: -40, east: 280),
          _offset(north: 40, east: 280),
          _offset(north: 40, east: 200),
        ],
      ]);

      final state = _feed(detector, _origin, 31);

      expect(state.isAshore, isTrue);
      expect(state.landSideDistanceMeters, closeTo(40, 1));
    });
  });
}
