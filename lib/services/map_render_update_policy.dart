import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/boat_model.dart';
import '../types/boat_type.dart';
import '../utils/geo_math.dart';

/// Google Mapの表示更新にだけ使う省電力ポリシー。
/// 衝突判定・GPS取得・警告周期には影響させない。
const mapCameraMinMoveMeters = 0.75;
const mapCameraMinBearingChangeDegrees = 2.0;
const mapCameraMinZoomChange = 0.01;
const earthCircumferenceMetersAtEquator = 156543.03392;

/// 現在地への再追跡時に使う地図倍率を返す。
///
/// 利用者が航行中に選んだ拡大・縮小倍率を保つ。Google Mapsから不正な
/// 値が返る場合だけ、初期表示と同じ倍率へ安全に戻す。
double zoomForMapRefocus(
  double currentZoomLevel, {
  double fallbackZoomLevel = 18.0,
}) {
  return currentZoomLevel.isFinite ? currentZoomLevel : fallbackZoomLevel;
}

const shipDomainMinRefreshInterval = Duration(seconds: 2);
const shipDomainMaxRefreshInterval = Duration(seconds: 4);
const shipDomainMinMoveMeters = 1.5;
const shipDomainMinHeadingChangeDegrees = 5.0;
const shipDomainMinSpeedChangeMetersPerSecond = 0.3;
const shipDomainDisplayStepMeters = 2.0;
const shipDomainMaxSamplesPerBoat = 24;

/// 船舶領域の表示用サンプル距離を返す。
///
/// 安全判定は別の連続判定経路で行うため、ここではGoogle Mapsへ渡す
/// Polygon数だけを有界化する。短距離は従来相当の約2m間隔、長距離は
/// 始点と終点を含む最大24点へ自動的に粗化する。
List<double> shipDomainDisplaySampleDistances(double maxDistanceMeters) {
  if (!maxDistanceMeters.isFinite || maxDistanceMeters <= 0) {
    return const [0.0];
  }
  final desiredIntervals = (maxDistanceMeters / shipDomainDisplayStepMeters)
      .ceil()
      .clamp(1, shipDomainMaxSamplesPerBoat - 1);
  return List<double>.generate(
    desiredIntervals + 1,
    (index) => maxDistanceMeters * index / desiredIntervals,
    growable: false,
  );
}

/// 非同期の地図描画要求に世代番号を付け、最新要求だけを反映させる。
///
/// Future自体はキャンセルできないため、新しい要求の開始後に
/// 古いFutureが完了しても、[isLatest]でcommitを拒否する。
class LatestMapRenderGate {
  int _latestGeneration = 0;

  MapRenderRequest begin() {
    _latestGeneration += 1;
    return MapRenderRequest._(_latestGeneration);
  }

  bool isLatest(MapRenderRequest request) {
    return request._generation == _latestGeneration;
  }

  /// 地図controllerの交換や外部からのマーカー置換時に、
  /// 実行中の描画結果を無効化する。
  void invalidate() {
    _latestGeneration += 1;
  }
}

class MapRenderRequest {
  final int _generation;

  const MapRenderRequest._(this._generation);
}

class MapRenderDiff<K> {
  final Set<K> upsertedKeys;
  final Set<K> removedKeys;

  MapRenderDiff({
    required Iterable<K> upsertedKeys,
    required Iterable<K> removedKeys,
  })  : upsertedKeys = Set.unmodifiable(upsertedKeys),
        removedKeys = Set.unmodifiable(removedKeys);

  bool get isEmpty => upsertedKeys.isEmpty && removedKeys.isEmpty;
}

/// 前回と値が変わったkeyだけを再生成対象にする。
///
/// [V]の`==`を描画入力の同一性判定に使う。マーカー本体ではなく、
/// 位置・方位・表示文言・アイコンサイズ等の軽量な入力値を渡す。
MapRenderDiff<K> diffMapRenderState<K, V>({
  required Map<K, V> previous,
  required Map<K, V> next,
}) {
  final upserted = <K>{};
  for (final entry in next.entries) {
    if (!previous.containsKey(entry.key) ||
        previous[entry.key] != entry.value) {
      upserted.add(entry.key);
    }
  }
  return MapRenderDiff<K>(
    upsertedKeys: upserted,
    removedKeys: previous.keys.where((key) => !next.containsKey(key)),
  );
}

double shortestBearingDifference(double a, double b) {
  final normalized = ((a - b) % 360 + 360) % 360;
  return normalized > 180 ? 360 - normalized : normalized;
}

/// 指定緯度・ズームでの艇アイコン用の物理解像度（物理px/m）。
/// Google Maps のWeb Mercator縮尺から求め、BitmapDescriptorの物理pxへ
/// 変換するために端末DPRを掛ける。
double mapPixelsPerMeterAt({
  required double latitude,
  required double zoomLevel,
  required double devicePixelRatio,
}) {
  final safeLatitude = latitude.isFinite ? latitude.clamp(-85.0, 85.0) : 0.0;
  final safeZoom = zoomLevel.isFinite ? zoomLevel.clamp(0.0, 22.0) : 18.0;
  final safeDpr = devicePixelRatio.isFinite && devicePixelRatio > 0
      ? devicePixelRatio
      : 1.0;
  final metersPerLogicalPixel = earthCircumferenceMetersAtEquator *
      math.cos(safeLatitude * math.pi / 180) /
      math.pow(2, safeZoom);
  return safeDpr / metersPerLogicalPixel;
}

class CameraRenderSnapshot {
  final LatLng target;
  final double bearing;
  final double zoom;

  const CameraRenderSnapshot({
    required this.target,
    required this.bearing,
    required this.zoom,
  });
}

class MapCameraUpdateGate {
  CameraRenderSnapshot? _lastRendered;

  bool shouldUpdate(CameraRenderSnapshot next, {bool force = false}) {
    final previous = _lastRendered;
    if (force || previous == null) return true;
    return distanceMeters(previous.target, next.target) >=
            mapCameraMinMoveMeters ||
        shortestBearingDifference(previous.bearing, next.bearing) >=
            mapCameraMinBearingChangeDegrees ||
        (previous.zoom - next.zoom).abs() >= mapCameraMinZoomChange;
  }

  void markRendered(CameraRenderSnapshot snapshot) {
    _lastRendered = snapshot;
  }

  void reset() {
    _lastRendered = null;
  }
}

class BoatRenderSnapshot {
  final String boatId;
  final BoatType boatType;
  final LatLng position;
  final double heading;
  final double speed;

  const BoatRenderSnapshot({
    required this.boatId,
    required this.boatType,
    required this.position,
    required this.heading,
    required this.speed,
  });

  factory BoatRenderSnapshot.fromBoat(Boat boat) {
    return BoatRenderSnapshot(
      boatId: boat.boatId,
      boatType: boat.boatType,
      position: LatLng(boat.lat, boat.lng),
      heading: boat.heading,
      speed: boat.speed,
    );
  }
}

class ShipDomainRenderSnapshot {
  final DateTime renderedAt;
  final double warningTimeSeconds;
  final Map<String, BoatRenderSnapshot> boats;

  ShipDomainRenderSnapshot({
    required this.renderedAt,
    required this.warningTimeSeconds,
    required Iterable<BoatRenderSnapshot> boats,
  }) : boats = {for (final boat in boats) boat.boatId: boat};
}

bool shouldRefreshShipDomains({
  required ShipDomainRenderSnapshot? previous,
  required ShipDomainRenderSnapshot next,
}) {
  if (previous == null) return true;
  if (previous.warningTimeSeconds != next.warningTimeSeconds) return true;
  if (previous.boats.length != next.boats.length ||
      !previous.boats.keys.toSet().containsAll(next.boats.keys)) {
    return true;
  }

  // 艇の追加・削除・種類変更は、最短周期を待たず画面へ反映する。
  for (final entry in next.boats.entries) {
    final before = previous.boats[entry.key]!;
    if (before.boatType != entry.value.boatType) return true;
  }

  final elapsed = next.renderedAt.difference(previous.renderedAt);
  if (elapsed < shipDomainMinRefreshInterval) return false;
  if (elapsed >= shipDomainMaxRefreshInterval) return true;

  for (final entry in next.boats.entries) {
    final before = previous.boats[entry.key]!;
    final after = entry.value;
    if (distanceMeters(before.position, after.position) >=
            shipDomainMinMoveMeters ||
        shortestBearingDifference(before.heading, after.heading) >=
            shipDomainMinHeadingChangeDegrees ||
        (before.speed - after.speed).abs() >=
            shipDomainMinSpeedChangeMetersPerSecond) {
      return true;
    }
  }
  return false;
}
