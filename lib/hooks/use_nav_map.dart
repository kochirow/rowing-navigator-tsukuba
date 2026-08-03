import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../config/boat_config.dart';
import '../config/map_style_config.dart';
import '../services/map_render_update_policy.dart';
import '../types/marker_type.dart';
import '../types/boat_type.dart';
import '../utils/image2icon.dart';

UseNavMap useNavMap() {
  final mapController = useState<GoogleMapController?>(null);
  final mapType = useState(MapType.normal);
  final markers = useState<Set<Marker>>({});
  final polylines = useState<Set<Polyline>>({});
  final polygons = useState<Set<Polygon>>({});
  final isReady = useState(false);
  final nameLabelIcons = useRef(<String, BitmapDescriptor>{});
  final boatIcons = useRef(<String, Future<BitmapDescriptor>>{});
  final cameraUpdateGate = useMemoized(MapCameraUpdateGate.new);
  final markerRenderGate = useMemoized(LatestMapRenderGate.new);
  final boatMarkerCache = useRef(<String, _CachedBoatMarkerRender>{});
  const blueBoatIconPath = 'assets/icons/blue_boat.png';
  const redBoatIconPath = 'assets/icons/red_boat.png';

  void setController(GoogleMapController controller) {
    cameraUpdateGate.reset();
    markerRenderGate.invalidate();
    boatMarkerCache.value.clear();
    mapController.value = controller;
    isReady.value = true;
  }

  Future<double> getZoomLevel() {
    return mapController.value!.getZoomLevel();
  }

  setMapType(MapType newMapType) {
    mapType.value = newMapType;
  }

  void setMarkers(Set<Marker> newMarkers) {
    // 個別編集画面等からの置換を、実行中の古い描画で戻さない。
    markerRenderGate.invalidate();
    boatMarkerCache.value.clear();
    markers.value = newMarkers;
  }

  void setPolylines(Set<Polyline> newPolylines) {
    polylines.value = newPolylines;
  }

  void setPolygons(Set<Polygon> newPolygons) {
    polygons.value = newPolygons;
  }

  Future<Marker> createMarkerAtIconSize(
    String markerId,
    MarkerType type,
    double lat,
    double lng,
    double heading,
    String title,
    String snippet,
    int iconSize, {
    double? imagePixelRatio,
  }) async {
    final iconPath =
        type == MarkerType.myBoat ? redBoatIconPath : blueBoatIconPath;
    final cacheKey = '$iconPath@$iconSize@${imagePixelRatio ?? 1.0}';
    final iconFuture =
        boatIcons.value[cacheKey] ??= getBitmapDescriptorFromAssetBytes(
      iconPath,
      iconSize,
      imagePixelRatio: imagePixelRatio,
    );
    late final BitmapDescriptor icon;
    try {
      icon = await iconFuture;
    } catch (_) {
      // 一時的なasset読み込み失敗を永続キャッシュしない。
      if (identical(boatIcons.value[cacheKey], iconFuture)) {
        boatIcons.value.remove(cacheKey);
      }
      rethrow;
    }
    return Marker(
      markerId: MarkerId(markerId),
      position: LatLng(lat, lng),
      icon: icon,
      infoWindow: InfoWindow(title: title, snippet: snippet),
      anchor: const Offset(0.5, 0.5),
      rotation: heading,
      flat: true,
    );
  }

  Future<Marker> createBoatArrowMarker(
    BoatMarkerRenderSpec spec,
    double zoomLevel,
  ) async {
    final boatConfig = boatConfigs.byBoatType(spec.boatType);
    final params = boatConfig.shipDomainParams.shipBodyParam;
    final dpr = WidgetsBinding.instance.platformDispatcher.views.isEmpty
        ? 1.0
        : WidgetsBinding
            .instance.platformDispatcher.views.first.devicePixelRatio;
    final pixelsPerMeter = mapPixelsPerMeterAt(
      latitude: spec.lat,
      zoomLevel: zoomLevel,
      devicePixelRatio: dpr,
    );
    final cacheKey = [
      spec.type.name,
      spec.boatType.name,
      params.h.toStringAsFixed(3),
      boatConfig.displayHullWidthMeters.toStringAsFixed(3),
      pixelsPerMeter.toStringAsFixed(4),
      dpr.toStringAsFixed(2),
      minBoatMarkerLengthPixels.toString(),
      maxBoatMarkerLengthPixels.toString(),
    ].join('@');
    final iconFuture =
        boatIcons.value[cacheKey] ??= getBoatHomePlateBitmapDescriptor(
      lengthMeters: params.h,
      // 判定用の幅(オーを含む6〜7.5m)ではなく、船体の実幅。
      // 安全ポリゴンと矢羽の役割を視覚的に分ける。
      widthMeters: boatConfig.displayHullWidthMeters,
      color: spec.type == MarkerType.myBoat ? Colors.red : Colors.blue,
      pixelsPerMeter: pixelsPerMeter,
      minPixels: (minBoatMarkerLengthPixels * dpr).round(),
      maxPixels: (maxBoatMarkerLengthPixels * dpr).round(),
    );
    late final BitmapDescriptor icon;
    try {
      icon = await iconFuture;
    } catch (_) {
      if (identical(boatIcons.value[cacheKey], iconFuture)) {
        boatIcons.value.remove(cacheKey);
      }
      // 既存PNGはCanvas描画が利用できない端末でだけ使うフォールバック。
      return createMarkerAtIconSize(
        spec.markerId,
        spec.type,
        spec.lat,
        spec.lng,
        spec.heading,
        spec.title,
        spec.snippet,
        // [getBitmapDescriptorFromAssetBytes] は物理pxで受ける。Canvasの
        // ホームベース型と同じ最小論理サイズを維持し、縮退時だけ極小にならないようにする。
        (minBoatMarkerLengthPixels * dpr).round(),
        imagePixelRatio: dpr,
      );
    }
    return Marker(
      markerId: MarkerId(spec.markerId),
      position: LatLng(spec.lat, spec.lng),
      icon: icon,
      infoWindow: InfoWindow(title: spec.title, snippet: spec.snippet),
      anchor: const Offset(0.5, 0.5),
      rotation: spec.heading,
      flat: true,
    );
  }

  Future<Marker> createMarker(String markerId, MarkerType type, double lat,
      double lng, double heading, String title, String snippet) async {
    return createMarkerAtIconSize(
      markerId,
      type,
      lat,
      lng,
      heading,
      title,
      snippet,
      minBoatMarkerLengthPixels,
    );
  }

  Future<Marker> createNameMarker(
    String markerId,
    double lat,
    double lng,
    String displayName,
  ) async {
    final icon = nameLabelIcons.value[displayName] ??=
        await getNameLabelBitmapDescriptor(displayName);
    return Marker(
      markerId: MarkerId('${markerId}_name'),
      position: LatLng(lat, lng),
      icon: icon,
      anchor: const Offset(0.5, 1),
      flat: false,
    );
  }

  /// 全艇分の表示入力を受け取るが、実際に再生成するのは変化した艇だけ。
  ///
  /// ズーム値はこの1描画で一度だけ取得する。実行中に次の要求が
  /// 始まった場合は、古い非同期結果を[markers]へ反映しない。
  Future<bool> renderBoatMarkers(
    Iterable<BoatMarkerRenderSpec> boatSpecs,
  ) async {
    final request = markerRenderGate.begin();
    final controller = mapController.value;
    if (controller == null) return false;

    final specsById = <String, BoatMarkerRenderSpec>{
      for (final spec in boatSpecs) spec.markerId: spec,
    };
    late final double zoomLevel;
    try {
      zoomLevel = await controller.getZoomLevel();
    } catch (_) {
      // 既に次の描画が始まっている場合、古いcontroller由来の
      // 失敗を新しい描画のエラーとして表面化させない。
      if (!markerRenderGate.isLatest(request)) return false;
      rethrow;
    }
    if (!markerRenderGate.isLatest(request)) return false;
    final nextFingerprints = <String, _BoatMarkerRenderFingerprint>{
      for (final entry in specsById.entries)
        entry.key: _BoatMarkerRenderFingerprint(
          entry.value,
          mapPixelsPerMeterAt(
            latitude: entry.value.lat,
            zoomLevel: zoomLevel,
            devicePixelRatio:
                WidgetsBinding.instance.platformDispatcher.views.isEmpty
                    ? 1.0
                    : WidgetsBinding.instance.platformDispatcher.views.first
                        .devicePixelRatio,
          ),
        ),
    };
    final previousFingerprints = <String, _BoatMarkerRenderFingerprint>{
      for (final entry in boatMarkerCache.value.entries)
        entry.key: entry.value.fingerprint,
    };
    final diff = diffMapRenderState(
      previous: previousFingerprints,
      next: nextFingerprints,
    );

    late final List<MapEntry<String, _CachedBoatMarkerRender>> rebuiltEntries;
    try {
      rebuiltEntries = await Future.wait(
        diff.upsertedKeys.map((markerId) async {
          final spec = specsById[markerId]!;
          final rendered = <Marker>{
            await createBoatArrowMarker(spec, zoomLevel),
          };
          final nameLabel = spec.nameLabel;
          if (nameLabel != null && nameLabel.isNotEmpty) {
            rendered.add(await createNameMarker(
              spec.markerId,
              spec.lat,
              spec.lng,
              nameLabel,
            ));
          }
          return MapEntry(
            markerId,
            _CachedBoatMarkerRender(
              fingerprint: nextFingerprints[markerId]!,
              markers: rendered,
            ),
          );
        }),
      );
    } catch (_) {
      if (!markerRenderGate.isLatest(request)) return false;
      rethrow;
    }
    if (!markerRenderGate.isLatest(request)) return false;

    final rebuiltById = Map<String, _CachedBoatMarkerRender>.fromEntries(
      rebuiltEntries,
    );
    final nextCache = <String, _CachedBoatMarkerRender>{};
    for (final markerId in specsById.keys) {
      final rebuilt = rebuiltById[markerId];
      final cached = boatMarkerCache.value[markerId];
      if (rebuilt != null) {
        nextCache[markerId] = rebuilt;
      } else if (cached != null) {
        nextCache[markerId] = cached;
      }
    }
    boatMarkerCache.value
      ..clear()
      ..addAll(nextCache);
    markers.value = {
      for (final entry in nextCache.values) ...entry.markers,
    };
    return true;
  }

  Marker createHiddenMarker(
    String markerId,
    LatLng position,
    void Function()? onTap,
  ) {
    return Marker(
      markerId: MarkerId(markerId),
      position: position,
      infoWindow: InfoWindow(title: "削除", onTap: onTap),
      anchor: const Offset(0.5, 0), // 表示位置を調整
      alpha: 0, // Markerを非表示
    );
  }

  Polygon createPolygon(
      String polygonId, List<LatLng> points, void Function()? onTap) {
    return Polygon(
      polygonId: PolygonId(polygonId),
      points: points,
      strokeWidth: 2,
      strokeColor: Colors.red,
      fillColor: Colors.red.withValues(alpha: 0.4),
      consumeTapEvents: true, // タップイベントを受け取る
      onTap: onTap,
    );
  }

  Polyline createPolyline(List<LatLng> points) {
    return Polyline(
      polylineId: const PolylineId("drawing_line"),
      points: points,
      width: 2,
      color: Colors.red,
    );
  }

  Future<bool> focus(double lat, double lng, double heading, double zoomLevel,
      {bool force = false}) async {
    CameraPosition camPos;
    camPos = CameraPosition(
      target: LatLng(lat, lng),
      bearing: heading,
      zoom: zoomLevel,
    );
    final snapshot = CameraRenderSnapshot(
      target: camPos.target,
      bearing: camPos.bearing,
      zoom: camPos.zoom,
    );
    if (!cameraUpdateGate.shouldUpdate(snapshot, force: force)) return false;
    // 航行中は毎秒更新されるため、アニメーションを重ねず即時反映する。
    // これにより古い方位へのアニメーションが残って追従解除されるのを防ぐ。
    await mapController.value!.moveCamera(
      CameraUpdate.newCameraPosition(camPos),
    );
    cameraUpdateGate.markRendered(snapshot);
    return true;
  }

  /// 指定した地点がすべて収まる位置へカメラを動かす。監視モード専用。
  ///
  /// 航行中は使わない。漕手の画面は自艇を追い続ける必要があり、勝手に
  /// 引くと前方の見通しが失われる。
  ///
  /// 1点だけのとき、または全艇がほぼ同じ場所にいて範囲が潰れるときは、
  /// bounds が面積を持たず Google Maps が最大倍率まで寄せてしまうため、
  /// 単純な中心移動へ切り替える。
  Future<void> fitBounds(
    List<LatLng> points, {
    double singlePointZoom = watchSingleBoatZoomLevel,
    double paddingPixels = 64,
  }) async {
    final controller = mapController.value;
    if (controller == null || points.isEmpty) return;
    // 手動でカメラを動かすため、差分ゲートの記憶を捨てる。これを忘れると、
    // 次の focus() が「もう描いた」と誤判定されて画面が動かなくなる。
    cameraUpdateGate.reset();
    var south = points.first.latitude;
    var north = points.first.latitude;
    var west = points.first.longitude;
    var east = points.first.longitude;
    for (final point in points) {
      south = min(south, point.latitude);
      north = max(north, point.latitude);
      west = min(west, point.longitude);
      east = max(east, point.longitude);
    }
    // 約1m。これ未満の広がりは「1点」として扱う。
    const degenerateSpanDegrees = 1e-5;
    if (north - south < degenerateSpanDegrees &&
        east - west < degenerateSpanDegrees) {
      await controller.moveCamera(CameraUpdate.newLatLngZoom(
        LatLng((north + south) / 2, (east + west) / 2),
        singlePointZoom,
      ));
      return;
    }
    // south/west は最小、north/east は最大。逆にすると Google Maps が
    // assert で落ちる。
    await controller.animateCamera(CameraUpdate.newLatLngBounds(
      LatLngBounds(
        southwest: LatLng(south, west),
        northeast: LatLng(north, east),
      ),
      paddingPixels,
    ));
  }

  useEffect(() {
    return () {
      markerRenderGate.invalidate();
      // GoogleMap Stateがcontrollerを破棄するため、ここでは二重disposeしない。
    };
  }, []);

  return UseNavMap(
    mapController: mapController,
    mapType: mapType,
    getZoomLevel: getZoomLevel,
    markers: markers,
    polylines: polylines,
    polygons: polygons,
    isReady: isReady,
    setController: setController,
    setMapType: setMapType,
    createMarker: createMarker,
    createNameMarker: createNameMarker,
    renderBoatMarkers: renderBoatMarkers,
    createHiddenMarker: createHiddenMarker,
    createPolyline: createPolyline,
    createPolygon: createPolygon,
    setMarkers: setMarkers,
    setPolylines: setPolylines,
    setPolygons: setPolygons,
    focus: focus,
    fitBounds: fitBounds,
  );
}

class UseNavMap {
  final ValueNotifier<GoogleMapController?> mapController;
  final ValueNotifier<MapType> mapType;
  final Future<double> Function() getZoomLevel;
  final ValueNotifier<Set<Marker>> markers;
  final ValueNotifier<Set<Polyline>> polylines;
  final ValueNotifier<Set<Polygon>> polygons;
  final ValueNotifier<bool> isReady;
  final void Function(GoogleMapController controller) setController;
  final void Function(MapType newMapType) setMapType;
  final Future<Marker> Function(String markerId, MarkerType type, double lat,
      double lng, double heading, String title, String snippet) createMarker;
  final Future<Marker> Function(
    String markerId,
    double lat,
    double lng,
    String displayName,
  ) createNameMarker;
  final Future<bool> Function(
    Iterable<BoatMarkerRenderSpec> boatSpecs,
  ) renderBoatMarkers;
  final Marker Function(
          String markerId, LatLng position, void Function()? onTap)
      createHiddenMarker;
  final Polygon Function(
          String polygonId, List<LatLng> points, void Function()? onTap)
      createPolygon;
  final Polyline Function(List<LatLng> points) createPolyline;
  final void Function(Set<Marker> newMarkers) setMarkers;
  final void Function(Set<Polyline> newPolylines) setPolylines;
  final void Function(Set<Polygon> newPolygons) setPolygons;
  final Future<bool> Function(
    double lat,
    double lng,
    double heading,
    double zoomLevel, {
    bool force,
  }) focus;
  final Future<void> Function(
    List<LatLng> points, {
    double singlePointZoom,
    double paddingPixels,
  }) fitBounds;

  UseNavMap({
    required this.mapController,
    required this.mapType,
    required this.getZoomLevel,
    required this.markers,
    required this.polylines,
    required this.polygons,
    required this.isReady,
    required this.setController,
    required this.setMapType,
    required this.createMarker,
    required this.createNameMarker,
    required this.renderBoatMarkers,
    required this.createHiddenMarker,
    required this.createPolyline,
    required this.createPolygon,
    required this.setMarkers,
    required this.setPolylines,
    required this.setPolygons,
    required this.focus,
    required this.fitBounds,
  });
}

class BoatMarkerRenderSpec {
  final String markerId;
  final MarkerType type;
  final BoatType boatType;
  final double lat;
  final double lng;
  final double heading;
  final String title;
  final String snippet;

  /// `null`の場合は名前ラベルを作らない。監視モードだけ指定する。
  final String? nameLabel;

  const BoatMarkerRenderSpec({
    required this.markerId,
    required this.type,
    required this.boatType,
    required this.lat,
    required this.lng,
    required this.heading,
    required this.title,
    required this.snippet,
    this.nameLabel,
  });

  @override
  bool operator ==(Object other) {
    return other is BoatMarkerRenderSpec &&
        markerId == other.markerId &&
        type == other.type &&
        boatType == other.boatType &&
        lat == other.lat &&
        lng == other.lng &&
        heading == other.heading &&
        title == other.title &&
        snippet == other.snippet &&
        nameLabel == other.nameLabel;
  }

  @override
  int get hashCode => Object.hash(
        markerId,
        type,
        boatType,
        lat,
        lng,
        heading,
        title,
        snippet,
        nameLabel,
      );
}

class _BoatMarkerRenderFingerprint {
  final BoatMarkerRenderSpec spec;
  final double pixelsPerMeter;

  const _BoatMarkerRenderFingerprint(this.spec, this.pixelsPerMeter);

  @override
  bool operator ==(Object other) {
    return other is _BoatMarkerRenderFingerprint &&
        spec == other.spec &&
        pixelsPerMeter == other.pixelsPerMeter;
  }

  @override
  int get hashCode => Object.hash(spec, pixelsPerMeter);
}

class _CachedBoatMarkerRender {
  final _BoatMarkerRenderFingerprint fingerprint;
  final Set<Marker> markers;

  _CachedBoatMarkerRender({
    required this.fingerprint,
    required Iterable<Marker> markers,
  }) : markers = Set.unmodifiable(markers);
}
