import 'dart:collection';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/models/static_obstacle_model.dart';

import '../types/map_editor_mode.dart';
import '../utils/mean_lat_lng.dart';

UseMapEditor useMapEditor(GoogleMapController? mapController) {
  final mode = useState(MapEditorMode.select); // エディタのモード
  final obstacles = useState<List<StaticObstacleModel>>([]); // 障害物リスト
  /* spellchecker: disable */
  final polylineSet = useState(HashSet<Polyline>()); // Polyline
  final polygonSet = useState(HashSet<Polygon>()); // Polygon
  final markerSet = useState(HashSet<Marker>()); // Marker
  final drawingLinePoints = useState<List<LatLng>>([]); // 描画中の線の座標リスト
  final lastPoint = useState<LatLng?>(null); // 直前の描画座標
  // Constants
  final MIN_EDGE_LENGTH = 1.0; // ポリゴンの最小辺長

  void setMode(MapEditorMode newMode) {
    mode.value = newMode;
  }

  Polygon createPolygon(
      String polygonId, List<LatLng> points, void Function()? onTap) {
    return Polygon(
      polygonId: PolygonId(polygonId),
      points: points,
      strokeWidth: 2,
      strokeColor: Colors.red,
      fillColor: Colors.red.withOpacity(0.4),
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

  Marker createMarker(
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

  Future<LatLng> convertScreenCoordinateToLatLng(double x, double y) async {
    final controller = mapController!;
    final screenCoordinate = ScreenCoordinate(x: x.round(), y: y.round());
    return controller.getLatLng(screenCoordinate);
  }

  void erasePolyline() {
    drawingLinePoints.value = List<LatLng>.empty();
  }

  void draw(DragUpdateDetails details) async {
    // ドラッグ中の座標を取得
    double x, y;
    if (Platform.isAndroid) {
      x = details.localPosition.dx * 3;
      y = details.localPosition.dy * 3;
    } else {
      x = details.localPosition.dx;
      y = details.localPosition.dy;
    }
    // Widget座標 -> LatLngに変換
    final newPoint = await convertScreenCoordinateToLatLng(x, y);

    // 直前の座標との距離が短い場合は無視
    final lastPoint_ = lastPoint.value;
    if (lastPoint_ != null) {
      final distance = Geolocator.distanceBetween(lastPoint_.latitude,
          lastPoint_.longitude, newPoint.latitude, newPoint.longitude);
      if (distance < MIN_EDGE_LENGTH) return;
    }

    // 直前の座標を更新
    lastPoint.value = newPoint;

    // ポリラインを描画
    drawingLinePoints.value.add(newPoint);
    drawingLinePoints.value = List<LatLng>.from(drawingLinePoints.value);
  }

  void finishDraw(DragEndDetails details) async {
    // モードを戻す
    setMode(MapEditorMode.select);
    // 直前の座標を削除
    lastPoint.value = null;
    // 描画中の線が3点未満の場合は無視
    if (drawingLinePoints.value.length < 3) return;

    // 障害物を作成
    final areaId = DateTime.now().toString();
    final points = drawingLinePoints.value;
    final newObstacle =
        StaticObstacleModel(id: areaId, points: points); // 障害物を作成
    obstacles.value.add(newObstacle); // 障害物リストに追加
    obstacles.value = List<StaticObstacleModel>.from(obstacles.value);
    erasePolyline();
  }

  useEffect(() {
    // obastaclesに合わせてポリゴンを再描画
    final polygons = HashSet<Polygon>.from({}); // 新しいPolygonを作成
    final markers = HashSet<Marker>.from({}); // 新しいMarkerを作成

    for (final obstacle in obstacles.value) {
      // 障害物領域を作成
      final polygon = createPolygon(
        obstacle.id,
        obstacle.points,
        () => mapController!
            .showMarkerInfoWindow(MarkerId(obstacle.id)) // InfoWindowを表示
        ,
      );
      polygons.add(polygon);
      // 領域の中心にInfoWindowを配置
      final centerLatLng = getMeanLatLng(obstacle.points);
      final marker = createMarker(
        obstacle.id,
        centerLatLng,
        () {
          obstacles.value.removeWhere((o) => o.id == obstacle.id);
          obstacles.value = List<StaticObstacleModel>.from(obstacles.value);
        },
      );
      markers.add(marker);
    }
    // 描画を更新
    polygonSet.value = polygons;
    markerSet.value = markers;
    return null;
  }, [obstacles.value]);

  useEffect(() {
    if (drawingLinePoints.value.isEmpty) {
      polylineSet.value = HashSet<Polyline>.from({}); // 描画中の線を削除
    } else {
      // 描画中の線を描画
      final newPolyline = createPolyline(
        drawingLinePoints.value,
      );
      final polyline = HashSet<Polyline>.from({newPolyline});
      polylineSet.value = polyline; // 描画を更新
    }
    return null;
  }, [drawingLinePoints.value]);

  return UseMapEditor(
    mode: mode,
    polylineSet: polylineSet,
    drawingLinePoints: drawingLinePoints,
    polygonSet: polygonSet,
    markerSet: markerSet,
    lastPoint: lastPoint,
    draw: draw,
    finishDraw: finishDraw,
  );
}

class UseMapEditor {
  final ValueNotifier<MapEditorMode> mode;
  final ValueNotifier<HashSet<Polyline>> polylineSet;
  final ValueNotifier<List<LatLng>> drawingLinePoints;
  final ValueNotifier<HashSet<Polygon>> polygonSet;
  final ValueNotifier<HashSet<Marker>> markerSet;
  final ValueNotifier<LatLng?> lastPoint;
  final void Function(DragUpdateDetails details) draw;
  final void Function(DragEndDetails details) finishDraw;

  UseMapEditor({
    required this.mode,
    required this.polylineSet,
    required this.drawingLinePoints,
    required this.polygonSet,
    required this.markerSet,
    required this.lastPoint,
    required this.draw,
    required this.finishDraw,
  });
}
