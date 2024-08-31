import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/models/static_obstacle_model.dart';
import 'package:rowing_navigator/services/env_service.dart';
import 'package:rowing_navigator/utils/self_intersection.dart';

import '../types/map_editor_mode.dart';

UseMapEditor useMapEditor(GoogleMapController? mapController) {
  final mode = useState(MapEditorMode.select); // エディタのモード
  final obstacles = useState<List<StaticObstacle>>([]); // 障害物リスト
  final obstaclesSubscription =
      useState<StreamSubscription?>(null); // 障害物リストのStream
  /* spellchecker: disable */
  final drawingLinePoints = useState<List<LatLng>>([]); // 描画中の線の座標リスト
  final lastPoint = useState<LatLng?>(null); // 直前の描画座標
  // Services
  final env = EnvService();
  // Constants
  final MIN_EDGE_LENGTH = 1.0; // ポリゴンの最小辺長

  void setMode(MapEditorMode newMode) {
    mode.value = newMode;
  }

  void setLastPoint(LatLng? newPoint) {
    lastPoint.value = newPoint;
  }

  void setDrawingLinePoints(List<LatLng> newPoints) {
    drawingLinePoints.value = newPoints;
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
    List<LatLng> newPoints = drawingLinePoints.value;
    newPoints.add(newPoint);
    drawingLinePoints.value = List<LatLng>.from(newPoints);
  }

  void finishDraw(DragEndDetails details) async {
    // モードを戻す
    setMode(MapEditorMode.select);
    // 直前の座標を削除
    lastPoint.value = null;

    final points = drawingLinePoints.value;
    // 描画中の線が3点未満の場合・自己交差している場合は無視
    if (drawingLinePoints.value.length < 3 || isSelfIntersecting(points)) {
      print("Invalid polygon");
      erasePolyline();
      return;
    }

    // 障害物を作成
    final newObstacle = StaticObstacle(id: "dummy", points: points); // 障害物を作成
    await env.addStaticObstacle(newObstacle); // 障害物をDBに登録
    erasePolyline();
  }

  void deleteObstacle(String id) async {
    await env.deleteStaticObstacle(id); // 障害物をDBから削除
    obstacles.value.removeWhere((o) => o.id == id);
    obstacles.value = List<StaticObstacle>.from(obstacles.value);
  }

  void watchObstacles() {
    obstaclesSubscription.value =
        env.getStaticObstaclesStream().listen((staticObs) {
      List<StaticObstacle> obstacles_ = staticObs["obstacles"];
      obstacles.value = obstacles_;
    });
  }

  useEffect(() {
    watchObstacles();
    return () {
      obstaclesSubscription.value?.cancel();
    };
  }, []);

  return UseMapEditor(
    mode: mode,
    obstacles: obstacles,
    drawingLinePoints: drawingLinePoints,
    lastPoint: lastPoint,
    draw: draw,
    finishDraw: finishDraw,
    deleteObastacle: deleteObstacle,
    setMode: setMode,
    setLastPoint: setLastPoint,
    setDrawingLinePoints: setDrawingLinePoints,
  );
}

class UseMapEditor {
  final ValueNotifier<MapEditorMode> mode;
  final ValueNotifier<List<StaticObstacle>> obstacles;
  final ValueNotifier<List<LatLng>> drawingLinePoints;
  final ValueNotifier<LatLng?> lastPoint;
  final void Function(DragUpdateDetails details) draw;
  final void Function(DragEndDetails details) finishDraw;
  final void Function(String id) deleteObastacle;
  final void Function(MapEditorMode newMode) setMode;
  final void Function(LatLng? newPoint) setLastPoint;
  final void Function(List<LatLng> newPoints) setDrawingLinePoints;

  UseMapEditor({
    required this.mode,
    required this.obstacles,
    required this.drawingLinePoints,
    required this.lastPoint,
    required this.draw,
    required this.finishDraw,
    required this.deleteObastacle,
    required this.setMode,
    required this.setLastPoint,
    required this.setDrawingLinePoints,
  });
}
