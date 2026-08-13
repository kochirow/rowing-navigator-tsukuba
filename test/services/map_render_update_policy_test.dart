import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/services/map_render_update_policy.dart';
import 'package:rowing_navigator/types/boat_type.dart';

void main() {
  const origin = LatLng(36.069, 140.208);

  group('mapPixelsPerMeterAt', () {
    test('ズームを上げるほど実寸アイコンの物理px/mも増える', () {
      final at18 = mapPixelsPerMeterAt(
        latitude: 36,
        zoomLevel: 18,
        devicePixelRatio: 3,
      );
      final at19 = mapPixelsPerMeterAt(
        latitude: 36,
        zoomLevel: 19,
        devicePixelRatio: 3,
      );
      expect(at19, closeTo(at18 * 2, 0.000001));
    });

    test('Web Mercatorの緯度補正とDPRを反映する', () {
      final equator = mapPixelsPerMeterAt(
        latitude: 0,
        zoomLevel: 18,
        devicePixelRatio: 1,
      );
      final latitude36 = mapPixelsPerMeterAt(
        latitude: 36,
        zoomLevel: 18,
        devicePixelRatio: 1,
      );
      expect(latitude36, closeTo(equator / math.cos(36 * math.pi / 180), 1e-9));
    });
  });

  group('zoomForMapRefocus', () {
    test('keeps a user-selected zoom-out level', () {
      expect(zoomForMapRefocus(15.5), 15.5);
    });

    test('keeps a user-selected zoom-in level', () {
      expect(zoomForMapRefocus(19.25), 19.25);
    });

    test('uses the fallback only for an invalid zoom level', () {
      expect(zoomForMapRefocus(double.nan), 18.0);
    });
  });

  group('shipDomainDisplaySampleDistances', () {
    test('短距離は始点と終点を含む約2m間隔にする', () {
      final distances = shipDomainDisplaySampleDistances(5);
      expect(distances.first, 0);
      expect(distances.last, 5);
      expect(distances, hasLength(4));
    });

    test('高速艇・長い警告時間でも1艇24点を超えない', () {
      final distances = shipDomainDisplaySampleDistances(750);
      expect(distances.first, 0);
      expect(distances.last, 750);
      expect(distances, hasLength(shipDomainMaxSamplesPerBoat));
    });

    test('停止・異常距離は現在位置だけを返す', () {
      expect(shipDomainDisplaySampleDistances(0), [0]);
      expect(shipDomainDisplaySampleDistances(double.nan), [0]);
    });
  });

  group('LatestMapRenderGate', () {
    test('後から始めた描画だけを最新とする', () {
      final gate = LatestMapRenderGate();
      final first = gate.begin();
      expect(gate.isLatest(first), isTrue);

      final second = gate.begin();
      expect(gate.isLatest(first), isFalse);
      expect(gate.isLatest(second), isTrue);
    });

    test('invalidateで実行中の描画を無効化する', () {
      final gate = LatestMapRenderGate();
      final request = gate.begin();
      gate.invalidate();
      expect(gate.isLatest(request), isFalse);
    });

    test('古い非同期処理が後から完了してもcommitしない', () async {
      final gate = LatestMapRenderGate();
      final first = gate.begin();
      final firstWork = Completer<void>();
      var firstCommitted = false;
      final firstRender = () async {
        await firstWork.future;
        if (gate.isLatest(first)) firstCommitted = true;
      }();

      final second = gate.begin();
      firstWork.complete();
      await firstRender;

      expect(firstCommitted, isFalse);
      expect(gate.isLatest(second), isTrue);
    });
  });

  group('diffMapRenderState', () {
    test('追加・変更・削除を分離する', () {
      final diff = diffMapRenderState<String, int>(
        previous: const {'same': 1, 'changed': 2, 'removed': 3},
        next: const {'same': 1, 'changed': 20, 'added': 4},
      );

      expect(diff.upsertedKeys, {'changed', 'added'});
      expect(diff.removedKeys, {'removed'});
      expect(diff.isEmpty, isFalse);
    });

    test('入力が同じ艇は再生成対象にしない', () {
      final diff = diffMapRenderState<String, int>(
        previous: const {'boat-1': 1, 'boat-2': 2},
        next: const {'boat-1': 1, 'boat-2': 2},
      );

      expect(diff.isEmpty, isTrue);
    });
  });

  BoatRenderSnapshot boat({
    String id = 'boat-1',
    BoatType type = BoatType.r_1x,
    LatLng position = origin,
    double heading = 0,
    double speed = 3,
  }) {
    return BoatRenderSnapshot(
      boatId: id,
      boatType: type,
      position: position,
      heading: heading,
      speed: speed,
    );
  }

  ShipDomainRenderSnapshot snapshot(
    DateTime at, {
    Iterable<BoatRenderSnapshot>? boats,
    double warningTime = 10,
  }) {
    return ShipDomainRenderSnapshot(
      renderedAt: at,
      warningTimeSeconds: warningTime,
      boats: boats ?? [boat()],
    );
  }

  group('MapCameraUpdateGate', () {
    test('停止時の微小な位置・方位変化を省略する', () {
      final gate = MapCameraUpdateGate();
      const first = CameraRenderSnapshot(
        target: origin,
        bearing: 180,
        zoom: 18,
      );
      const tinyChange = CameraRenderSnapshot(
        target: LatLng(36.069002, 140.208002),
        bearing: 181,
        zoom: 18.005,
      );

      expect(gate.shouldUpdate(first), isTrue);
      gate.markRendered(first);
      expect(gate.shouldUpdate(tinyChange), isFalse);
    });

    test('一定以上の移動と手動追従は更新する', () {
      final gate = MapCameraUpdateGate();
      const first = CameraRenderSnapshot(
        target: origin,
        bearing: 180,
        zoom: 18,
      );
      const moved = CameraRenderSnapshot(
        target: LatLng(36.06902, 140.208),
        bearing: 180,
        zoom: 18,
      );

      gate.markRendered(first);
      expect(gate.shouldUpdate(moved), isTrue);
      expect(gate.shouldUpdate(first, force: true), isTrue);
    });

    test('reset()後は同じ位置でも更新する', () {
      // 「全艇を表示」のように、このゲートを通さず直接カメラを動かした後に
      // 記憶を捨てないと、次の追従要求が「もう描いた」と誤判定されて
      // 画面が固まる。艇一覧から艇を選んでもカメラが動かなくなる。
      final gate = MapCameraUpdateGate();
      const rendered = CameraRenderSnapshot(
        target: origin,
        bearing: 180,
        zoom: 18,
      );

      gate.markRendered(rendered);
      expect(gate.shouldUpdate(rendered), isFalse);
      gate.reset();
      expect(gate.shouldUpdate(rendered), isTrue);
    });
  });

  group('shouldRefreshShipDomains', () {
    final start = DateTime.utc(2026, 7, 21, 12);

    test('初回は必ず描画する', () {
      expect(
        shouldRefreshShipDomains(
          previous: null,
          next: snapshot(start),
        ),
        isTrue,
      );
    });

    test('移動中でも2秒未満の再生成を省略する', () {
      final previous = snapshot(start);
      final next = snapshot(
        start.add(const Duration(seconds: 1)),
        boats: [
          boat(position: const LatLng(36.06903, 140.208)),
        ],
      );
      expect(
        shouldRefreshShipDomains(previous: previous, next: next),
        isFalse,
      );
    });

    test('2秒後に意味のある移動があれば再生成する', () {
      final previous = snapshot(start);
      final next = snapshot(
        start.add(const Duration(seconds: 2)),
        boats: [
          boat(position: const LatLng(36.06903, 140.208)),
        ],
      );
      expect(
        shouldRefreshShipDomains(previous: previous, next: next),
        isTrue,
      );
    });

    test('停止中でも4秒ごとに最新化する', () {
      final previous = snapshot(start, boats: [boat(speed: 0)]);
      final next = snapshot(
        start.add(const Duration(seconds: 4)),
        boats: [boat(speed: 0)],
      );
      expect(
        shouldRefreshShipDomains(previous: previous, next: next),
        isTrue,
      );
    });

    test('艇の追加と警告時間の変更は即時反映する', () {
      final previous = snapshot(start);
      final oneSecondLater = start.add(const Duration(seconds: 1));
      expect(
        shouldRefreshShipDomains(
          previous: previous,
          next: snapshot(oneSecondLater, boats: [boat(), boat(id: 'boat-2')]),
        ),
        isTrue,
      );
      expect(
        shouldRefreshShipDomains(
          previous: previous,
          next: snapshot(oneSecondLater, warningTime: 12),
        ),
        isTrue,
      );
    });
  });
}
