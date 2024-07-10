import 'dart:io';
import 'dart:async';
import 'dart:math' as math;
import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:geolocator/geolocator.dart';
/* spellchecker: disable */
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../features/home_map/widgets/MapTypeSwitcher.dart';
import '../features/home_map/widgets/RoundedButton.dart';
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
    final mapType = useState(MapType.normal);
    final loading = useState(true);
    // Services
    final permission = PermissionService();
    final auth = AuthService();
    // Constants
    const LOCATION_ACCURACY = LocationAccuracy.bestForNavigation;

    final drawPolygonEnabled = useState(false);

    final polygonSet = useState(HashSet<Polygon>());
    final polylineSet = useState<HashSet<Polyline>>(HashSet<Polyline>());
    final latLngList = useState<List<LatLng>>([]);

    final lastXCoordinate = useState<int?>(null);
    final lastYCoordinate = useState<int?>(null);
    final lastLatLng = useState<LatLng?>(null);

    void _clearPolygons() {
      latLngList.value = [];
      polylineSet.value = HashSet.from({});
      polygonSet.value = HashSet.from({});
    }

    void _onPanUpdate(DragUpdateDetails details) async {
      double? x, y;

      if (Platform.isAndroid) {
        x = details.localPosition.dx * 3;
        y = details.localPosition.dy * 3;
      } else if (Platform.isIOS) {
        x = details.localPosition.dx;
        y = details.localPosition.dy;
      }

      if (x != null && y != null) {
        int xCoordinate = x.round();
        int yCoordinate = y.round();

        if (lastXCoordinate.value != null && lastYCoordinate.value != null) {
          var distance = math.sqrt(
              math.pow(xCoordinate - lastXCoordinate.value!, 2) +
                  math.pow(yCoordinate - lastYCoordinate.value!, 2));
          print(distance);
          if (distance > 80) return;
        }

        final GoogleMapController controller = navMap.mapController!;
        ScreenCoordinate screenCoordinate =
            ScreenCoordinate(x: xCoordinate, y: yCoordinate);
        LatLng latLng = await controller.getLatLng(screenCoordinate);

        if (lastLatLng.value != null) {
          final distance = Geolocator.distanceBetween(
              lastLatLng.value!.latitude,
              lastLatLng.value!.longitude,
              latLng.latitude,
              latLng.longitude);
          if (distance < 1) return;
        }

        lastXCoordinate.value = xCoordinate;
        lastYCoordinate.value = yCoordinate;
        lastLatLng.value = latLng;

        try {
          latLngList.value.add(latLng);

          polylineSet.value.removeWhere(
              (polyline) => polyline.polylineId.value == 'user_polyline');
          polylineSet.value.add(
            Polyline(
              polylineId: const PolylineId('user_polyline'),
              points: latLngList.value,
              width: 2,
              color: Colors.red,
            ),
          );
        } catch (e) {
          print(e);
        }
        polygonSet.value = HashSet<Polygon>.from(polygonSet.value);
      }
    }

    void _onPanEnd(DragEndDetails details) async {
      lastXCoordinate.value = null;
      lastYCoordinate.value = null;

      polygonSet.value
          .removeWhere((polygon) => polygon.polygonId.value == 'user_polygon');
      polygonSet.value.add(
        Polygon(
          polygonId: const PolygonId('user_polygon'),
          points: latLngList.value,
          strokeWidth: 2,
          strokeColor: Colors.red,
          fillColor: Colors.red.withOpacity(0.4),
        ),
      );
      // drawPolygonEnabled.value = !drawPolygonEnabled.value;
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
              onPanUpdate: (drawPolygonEnabled.value) ? _onPanUpdate : null,
              onPanEnd: (drawPolygonEnabled.value) ? _onPanEnd : null,
              onScaleUpdate: (_) {
                print("onScaleUpdate");
              },
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
                                icon: Icons.edit,
                                onPressed: () {
                                  drawPolygonEnabled.value = true;
                                },
                              ),
                            ),
                            Container(
                              margin: const EdgeInsets.only(top: 17),
                              child: RoundedIconButton(
                                icon: Icons.delete,
                                onPressed: () async {
                                  _clearPolygons();
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
