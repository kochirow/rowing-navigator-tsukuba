import 'dart:collection';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../types/map_editor_mode.dart';
import '../utils/mean_lat_lng.dart';

UseMapEditor useMapEditor(GoogleMapController? mapController) {
  final editorMode = useState(MapEditorMode.select);
  final polylineSet = useState(HashSet<Polyline>());
  final drawingLinePointsList = useState<List<LatLng>>([]);
  final polygonSet = useState(HashSet<Polygon>());
  final markerSet = useState(HashSet<Marker>());
  final lastPoint = useState<LatLng?>(null);
  final MIN_EDGE_LENGTH = 1.0;

  void clearPolygons() {
    drawingLinePointsList.value = [];
    polylineSet.value = HashSet.from({});
    polygonSet.value = HashSet.from({});
    markerSet.value = HashSet.from({});
  }

  void onPanUpdate(DragUpdateDetails details) async {
    // ドラッグ中の座標を取得
    double x, y;
    if (Platform.isAndroid) {
      x = details.localPosition.dx * 3;
      y = details.localPosition.dy * 3;
    } else {
      x = details.localPosition.dx;
      y = details.localPosition.dy;
    }

    // 座標をLatLngに変換
    final controller = mapController!;
    final screenCoordinate = ScreenCoordinate(x: x.round(), y: y.round());
    LatLng newPoint = await controller.getLatLng(screenCoordinate);

    // 直前の座標との距離が短い場合は無e視
    final lastPoint_ = lastPoint.value;
    if (lastPoint_ != null) {
      final distance = Geolocator.distanceBetween(lastPoint_.latitude,
          lastPoint_.longitude, newPoint.latitude, newPoint.longitude);
      if (distance < MIN_EDGE_LENGTH) return;
    }

    // 直前の座標を更新
    lastPoint.value = newPoint;

    // ポリラインを描画
    drawingLinePointsList.value.add(newPoint);
    polylineSet.value = HashSet<Polyline>.from({
      Polyline(
        polylineId: const PolylineId('drawing_line'),
        points: drawingLinePointsList.value,
        width: 2,
        color: Colors.red,
      )
    });
  }

  void onPanEnd(DragEndDetails details) async {
    // 描画中の線を削除
    polylineSet.value = HashSet<Polyline>.from({});
    // モードを戻す
    editorMode.value = MapEditorMode.select;

    // 描画中の線が3点未満の場合は無視
    if (drawingLinePointsList.value.length < 3) return;

    // ポリゴンを描画
    final areaId = DateTime.now().toString();
    final points = drawingLinePointsList.value;
    polygonSet.value.add(
      Polygon(
        polygonId: PolygonId(areaId),
        points: points,
        strokeWidth: 2,
        strokeColor: Colors.red,
        fillColor: Colors.red.withOpacity(0.4),
        consumeTapEvents: true, // タップイベントを受け取る
        onTap: () {
          mapController!
              .showMarkerInfoWindow(MarkerId(areaId)); // InfoWindowを表示
        },
      ),
    );
    polygonSet.value = HashSet<Polygon>.from(polygonSet.value); // 更新

    // ポリゴンの中心にInfoWindowを配置
    final centerLatLng = getMeanLatLng(points);
    markerSet.value.add(
      Marker(
        markerId: MarkerId(areaId),
        position: centerLatLng,
        infoWindow: InfoWindow(
            title: "削除",
            onTap: () {
              polygonSet.value
                  .removeWhere((polygon) => polygon.polygonId.value == areaId);
              markerSet.value
                  .removeWhere((marker) => marker.markerId.value == areaId);
              polygonSet.value = HashSet<Polygon>.from(polygonSet.value); // 更新
              markerSet.value = HashSet<Marker>.from(markerSet.value); // 更新
            }),
        anchor: const Offset(0.5, 0), // 表示位置を調整
        alpha: 0, // Markerを非表示
      ),
    );
    markerSet.value = HashSet<Marker>.from(markerSet.value); // 更新
  }

  return UseMapEditor(
    editorMode: editorMode,
    polylineSet: polylineSet,
    drawingLinePointsList: drawingLinePointsList,
    polygonSet: polygonSet,
    markerSet: markerSet,
    lastPoint: lastPoint,
    onPanUpdate: onPanUpdate,
    onPanEnd: onPanEnd,
    clearPolygons: clearPolygons,
  );
}

class UseMapEditor {
  final ValueNotifier<MapEditorMode> editorMode;
  final ValueNotifier<HashSet<Polyline>> polylineSet;
  final ValueNotifier<List<LatLng>> drawingLinePointsList;
  final ValueNotifier<HashSet<Polygon>> polygonSet;
  final ValueNotifier<HashSet<Marker>> markerSet;
  final ValueNotifier<LatLng?> lastPoint;
  final void Function(DragUpdateDetails details) onPanUpdate;
  final void Function(DragEndDetails details) onPanEnd;
  final void Function() clearPolygons;

  UseMapEditor({
    required this.editorMode,
    required this.polylineSet,
    required this.drawingLinePointsList,
    required this.polygonSet,
    required this.markerSet,
    required this.lastPoint,
    required this.onPanUpdate,
    required this.onPanEnd,
    required this.clearPolygons,
  });
}
