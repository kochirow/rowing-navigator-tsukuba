import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:geolocator/geolocator.dart';
/* spellchecker: disable */
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/types/map_editor_mode.dart';

import '../features/home_map/widgets/MapTypeSwitcher.dart';
import '../features/home_map/widgets/RoundedButton.dart';
import '../hooks/useMapEditor.dart';
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
    final mapEditor = useMapEditor(navMap.mapController);
    // State
    final mapType = useState(MapType.hybrid);
    final loading = useState(true);
    // Services
    final permission = PermissionService();
    final auth = AuthService();
    // Constants
    const LOCATION_ACCURACY = LocationAccuracy.bestForNavigation;

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
              onPanUpdate: (mapEditor.editorMode.value == MapEditorMode.edit)
                  ? mapEditor.onPanUpdate
                  : null,
              onPanEnd: (mapEditor.editorMode.value == MapEditorMode.edit)
                  ? mapEditor.onPanEnd
                  : null,
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
                  polylines: mapEditor.polylineSet.value,
                  polygons: mapEditor.polygonSet.value,
                  markers: mapEditor.markerSet.value,
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
                                icon: mapEditor.editorMode.value ==
                                        MapEditorMode.edit
                                    ? Icons.close
                                    : Icons.add,
                                onPressed: () {
                                  mapEditor.editorMode.value =
                                      mapEditor.editorMode.value ==
                                              MapEditorMode.select
                                          ? MapEditorMode.edit
                                          : MapEditorMode.select;
                                  mapEditor.lastPoint.value = null;
                                  mapEditor.drawingLinePointsList.value = [];
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
