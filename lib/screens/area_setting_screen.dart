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
import '../hooks/useMapEditor.dart';
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
    final mapEditor = useMapEditor(navMap.mapController.value);
    // State
    final loading = useState(true);
    final initLatLng = useState<LatLng?>(null);
    // Services
    final permission = PermissionService();
    final auth = AuthService();
    // Constants
    const LOCATION_ACCURACY = LocationAccuracy.bestForNavigation;
    const DEFAULT_ZOOM_LEVEL = 17.0;

    // ##########################
    // ログイン処理／初期位置の取得
    // ##########################
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
        // 初期位置の取得
        navMap.setMapType(MapType.hybrid);
        await permission.requestLocationServicePermission(); // 位置情報の許可取得
        final currentPosition = await Geolocator.getCurrentPosition(
            desiredAccuracy: LOCATION_ACCURACY);
        initLatLng.value =
            LatLng(currentPosition.latitude, currentPosition.longitude);
        loading.value = false;
      });
      return null;
    }, []);

    // ##########################
    // 障害物を描画
    // ##########################
    useEffect(() {
      if (!navMap.isReady.value) return;
      // obastaclesに合わせてポリゴンを再描画
      final polygons = HashSet<Polygon>.from({}); // 新しいPolygonを作成
      final markers = HashSet<Marker>.from({}); // 新しいMarkerを作成
      for (final obstacle in mapEditor.obstacles.value) {
        // 障害物領域を作成
        final polygon = navMap.createPolygon(
            obstacle.id,
            obstacle.points,
            () => navMap.mapController.value!
                .showMarkerInfoWindow(MarkerId(obstacle.id)) // InfoWindowを表示
            );
        polygons.add(polygon);
        // 領域の中心にInfoWindowを配置
        final centerLatLng = getMeanLatLng(obstacle.points);
        final marker = navMap.createHiddenMarker(
          obstacle.id,
          centerLatLng,
          () async {
            mapEditor.deleteObastacle(obstacle.id); // 障害物を削除
          },
        );
        markers.add(marker);
      }
      // 描画を更新
      navMap.setPolygons(polygons);
      navMap.setMarkers(markers);
      return null;
    }, [mapEditor.obstacles.value, navMap.isReady.value]);

    // ##########################
    // 描画中の線の描画
    // ##########################
    useEffect(() {
      final drawingLinePoints = mapEditor.drawingLinePoints.value;
      if (drawingLinePoints.isEmpty) {
        navMap.setPolylines({}); // 描画中の線を削除
      } else {
        // 描画中の線を描画
        final newPolyline = navMap.createPolyline(
          drawingLinePoints,
        );
        final polyline = HashSet<Polyline>.from({newPolyline});
        navMap.setPolylines(polyline); // 描画を更新
      }
      return null;
    }, [mapEditor.drawingLinePoints.value]);

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
              onPanUpdate: (mapEditor.mode.value == MapEditorMode.edit)
                  ? mapEditor.draw
                  : null,
              onPanEnd: (mapEditor.mode.value == MapEditorMode.edit)
                  ? mapEditor.finishDraw
                  : null,
              child: Stack(alignment: Alignment.center, children: <Widget>[
                // ################ マップ ################
                GoogleMap(
                  myLocationEnabled: true,
                  myLocationButtonEnabled: false,
                  initialCameraPosition: CameraPosition(
                    target: initLatLng.value!,
                    zoom: DEFAULT_ZOOM_LEVEL,
                  ),
                  mapType: navMap.mapType.value,
                  onMapCreated: (GoogleMapController controller) async {
                    navMap.setController(controller);
                  },
                  polylines: navMap.polylines.value,
                  polygons: navMap.polygons.value,
                  markers: navMap.markers.value,
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
                                  mapType: navMap.mapType.value,
                                  onTap: () {
                                    navMap.setMapType(
                                        navMap.mapType.value == MapType.normal
                                            ? MapType.hybrid
                                            : MapType.normal);
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
                                icon: mapEditor.mode.value == MapEditorMode.edit
                                    ? Icons.close
                                    : Icons.add,
                                onPressed: () {
                                  mapEditor.setMode(mapEditor.mode.value ==
                                          MapEditorMode.select
                                      ? MapEditorMode.edit
                                      : MapEditorMode.select);
                                  mapEditor.setLastPoint(null);
                                  mapEditor.setDrawingLinePoints([]);
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
                // Container(
                //   alignment: Alignment.bottomCenter,
                //   child: Padding(
                //     padding: const EdgeInsets.symmetric(
                //         vertical: 48, horizontal: 17),
                //     child: Column(
                //         mainAxisAlignment: MainAxisAlignment.end,
                //         crossAxisAlignment: CrossAxisAlignment.center,
                //         children: [
                //           RoundedButton(
                //             label: "Save",
                //             onPressed: () async {},
                //           ),
                //         ]),
                //   ),
                // ),
              ])),
    );
  }
}
