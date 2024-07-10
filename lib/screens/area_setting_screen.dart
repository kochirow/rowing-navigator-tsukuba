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
    // Services
    final permission = PermissionService();
    final auth = AuthService();
    // Constants
    const LOCATION_ACCURACY = LocationAccuracy.bestForNavigation;

    final drawPolygonEnabled = useState(false);
    final currentPosition = useState(const LatLng(0, 0));
    final clearDrawing = useState(false);
    final _controller = useMemoized(() => Completer<GoogleMapController>(), []);

    final polygonSet = useState(HashSet<Polygon>());
    final polylineSet = useState<HashSet<Polyline>>(HashSet<Polyline>());
    final latLngList = useState<List<LatLng>>([]);

    final loading = useState(true);

    final lastXCoordinate = useState<int?>(null);
    final lastYCoordinate = useState<int?>(null);
    final lastLatLng = useState<LatLng?>(null);

    void _clearPolygons() {
      latLngList.value.clear();
      polylineSet.value.clear();
      polygonSet.value.clear();
    }

    void _onPanUpdate(DragUpdateDetails details) async {
      if (clearDrawing.value) {
        clearDrawing.value = false;
        _clearPolygons();
      }

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
          if (distance > 80) return;
        }

        final GoogleMapController controller = await _controller.future;
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
      drawPolygonEnabled.value = !drawPolygonEnabled.value;
    }

    Future<Position> _determinePosition() async {
      bool serviceEnabled;
      LocationPermission permission;

      serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return Future.error('位置情報サービスが無効です。');
      }

      permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          return Future.error('位置情報を取得する権限がありません。');
        }
      }

      if (permission == LocationPermission.deniedForever) {
        return Future.error('位置情報サービスの権限が永久に拒否されています。権限を要求することができません。');
      }

      Position position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);
      loading.value = false;
      currentPosition.value = LatLng(position.latitude, position.longitude);
      return position;
    }

    void _toggleDrawing() {
      _clearPolygons();
      drawPolygonEnabled.value = !drawPolygonEnabled.value;
    }

    useEffect(() {
      loading.value = true;
      _determinePosition();
      return null;
    }, []);

    useEffect(() {
      // ログイン処理
      Future(() async {
        if (!auth.isSignedIn) {
          await auth.signInAnonymously();
          print("Signed in with temporary account.");
          print("UID: ${auth.currentUser?.uid}");
        } else {
          print("Already signed in.");
          print("UID: ${auth.currentUser?.uid}");
        }
      });
      return null;
    }, []);

    return Scaffold(
      appBar: AppBar(),
      body: loading.value
          ? const CircularProgressIndicator()
          : GestureDetector(
              onPanUpdate: (drawPolygonEnabled.value) ? _onPanUpdate : null,
              onPanEnd: (drawPolygonEnabled.value) ? _onPanEnd : null,
              child: Stack(alignment: Alignment.center, children: <Widget>[
                // ################ マップ ################
                GoogleMap(
                  myLocationEnabled: true,
                  myLocationButtonEnabled: false,
                  initialCameraPosition: navMap.initCamPos,
                  mapType: mapType.value,
                  onMapCreated: (GoogleMapController controller) async {
                    navMap.setController(controller);
                    _controller.complete(controller);
                    await permission.requestPermission(); // 位置情報の許可取得
                    final pos = await Geolocator.getCurrentPosition(
                        desiredAccuracy: LOCATION_ACCURACY);
                    await navMap.focus(pos.latitude, pos.longitude, 0, 17.0);
                  },
                  onCameraMoveStarted: () {},
                  // markers: navMap.markers,
                  polylines: polylineSet.value,
                  polygons: polygonSet.value,
                  circles: {
                    Circle(
                      circleId: const CircleId('lv2'),
                      center: currentPosition.value,
                      radius: 200,
                      fillColor: Colors.green.withOpacity(0.3),
                      strokeWidth: 0,
                      zIndex: -12,
                    ),
                    Circle(
                      circleId: const CircleId('lv3'),
                      center: currentPosition.value,
                      radius: 100,
                      fillColor: Colors.yellow.withOpacity(0.3),
                      strokeWidth: 0,
                      zIndex: -12,
                    ),
                    Circle(
                      circleId: const CircleId('lv4'),
                      center: currentPosition.value,
                      radius: 50,
                      fillColor: Colors.pink.withOpacity(0.3),
                      strokeWidth: 0,
                      zIndex: -11,
                    ),
                    Circle(
                      circleId: const CircleId('lv5'),
                      center: currentPosition.value,
                      radius: 10,
                      fillColor: Colors.red.withOpacity(0.5),
                      strokeWidth: 0,
                      zIndex: -10,
                    ),
                  },
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
                                onPressed: () {},
                              ),
                            ),
                            Container(
                              margin: const EdgeInsets.only(top: 17),
                              child: RoundedIconButton(
                                icon: Icons.delete,
                                onPressed: () async {},
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
      floatingActionButton: FloatingActionButton(
        onPressed: _toggleDrawing,
        backgroundColor: Theme.of(context).primaryColor,
        child: Icon(drawPolygonEnabled.value ? Icons.cancel : Icons.edit),
      ),
    );
  }
}
