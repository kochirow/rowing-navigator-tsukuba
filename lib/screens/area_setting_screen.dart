import 'dart:io';
import 'dart:async';
import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:geolocator/geolocator.dart';
/* spellchecker: disable */
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/types/map_editor_mode.dart';

import '../features/home_map/widgets/MapTypeSwitcher.dart';
import '../features/home_map/widgets/RoundedButton.dart';
import '../utils/mean_lat_lng.dart';
import '../widgets/RoundedIconButton.dart';
import '../hooks/useNavMap.dart';
import '../services/auth_service.dart';
import '../services/permission_service.dart';

class AreaSettingScreen extends HookConsumerWidget {
  const AreaSettingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Hooks
    final navMap = useNavMap();
    // State
    final mapType = useState(MapType.hybrid);
    final loading = useState(true);
    // Services
    final permission = PermissionService();
    final auth = AuthService();
    // Constants
    const LOCATION_ACCURACY = LocationAccuracy.bestForNavigation;

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
      final controller = navMap.mapController!;
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
            navMap.mapController!
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
                polygonSet.value.removeWhere(
                    (polygon) => polygon.polygonId.value == areaId);
                markerSet.value
                    .removeWhere((marker) => marker.markerId.value == areaId);
                polygonSet.value =
                    HashSet<Polygon>.from(polygonSet.value); // 更新
                markerSet.value = HashSet<Marker>.from(markerSet.value); // 更新
              }),
          anchor: const Offset(0.5, 0), // 表示位置を調整
          alpha: 0, // Markerを非表示
        ),
      );
      markerSet.value = HashSet<Marker>.from(markerSet.value); // 更新
    }

    useEffect(() {
      Future(() async {
        loading.value = true;
        // ログイン処理
        if (!auth.isSignedIn) {
          await auth.signInAnonymously();
          print("Signed in with temporary account.");
          print("UID: ${auth.currentUser?.uid}");
        } else {
          print("Already signed in.");
          print("UID: ${auth.currentUser?.uid}");
        }
        loading.value = false;
      });
      return null;
    }, []);

    return Scaffold(
      appBar: AppBar(),
      body: loading.value
          ? Center(
              child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                    margin: const EdgeInsets.only(bottom: 20),
                    child: const CircularProgressIndicator()),
                const Text("Loading...")
              ],
            ))
          : GestureDetector(
              onPanUpdate:
                  (editorMode.value == MapEditorMode.edit) ? onPanUpdate : null,
              onPanEnd:
                  (editorMode.value == MapEditorMode.edit) ? onPanEnd : null,
              child: Stack(alignment: Alignment.center, children: <Widget>[
                // ################ マップ ################
                GoogleMap(
                  myLocationEnabled: true,
                  myLocationButtonEnabled: false,
                  initialCameraPosition: navMap.initCamPos,
                  mapType: mapType.value,
                  onMapCreated: (GoogleMapController controller) async {
                    navMap.setController(controller);
                    await permission
                        .requestLocationServicePermission(); // 位置情報の許可取得
                    final pos = await Geolocator.getCurrentPosition(
                        desiredAccuracy: LOCATION_ACCURACY);
                    await navMap.focus(pos.latitude, pos.longitude, 0, 17.0);
                  },
                  onCameraMoveStarted: () {},
                  polylines: polylineSet.value,
                  polygons: polygonSet.value,
                  markers: markerSet.value,
                ),
                // ################ 左右操作ボタン類 ################
                Container(
                  alignment: Alignment.center,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        vertical: 48, horizontal: 17),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // ################ 左側 ################
                        Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Container(
                                margin: const EdgeInsets.only(top: 17),
                                child: MapTypeSwitcher(
                                  mapType: mapType.value,
                                  onTap: () {
                                    mapType.value =
                                        mapType.value == MapType.normal
                                            ? MapType.hybrid
                                            : MapType.normal;
                                  },
                                ))
                          ],
                        ),
                        // ################ 右側 ################
                        Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Container(
                              margin: const EdgeInsets.only(top: 17),
                              child: RoundedIconButton(
                                icon: editorMode.value == MapEditorMode.edit
                                    ? Icons.close
                                    : Icons.add,
                                onPressed: () {
                                  editorMode.value =
                                      editorMode.value == MapEditorMode.select
                                          ? MapEditorMode.edit
                                          : MapEditorMode.select;
                                  lastPoint.value = null;
                                  drawingLinePointsList.value = [];
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                // ################ ナビゲーションボタン ################
                Container(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        vertical: 48, horizontal: 17),
                    child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          RoundedButton(
                            label: "Save",
                            onPressed: () async {},
                          ),
                        ]),
                  ),
                ),
              ])),
    );
  }
}
