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

final drawPolygonEnabledProvider = StateProvider<bool>((ref) => false);
final clearDrawingProvider = StateProvider<bool>((ref) => false);
final polygonSetProvider = StateProvider<Set<Polygon>>((ref) => {});
final getUserLocationProvider =
    StateProvider<LatLng>((ref) => const LatLng(0, 0));

class AreaSettingScreen extends HookConsumerWidget {
  const AreaSettingScreen({super.key});

  // get math => null;

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

    final polylines = <Polyline>{
      const Polyline(
        polylineId: PolylineId("test"),
        points: [
          LatLng(35.133, 136.8373),
          LatLng(35.1334, 136.8374),
          LatLng(35.1335, 136.8372),
        ],
        color: Colors.red,
        width: 2,
      ),
    };
    final polygons = <Polygon>{
      Polygon(
        polygonId: const PolygonId("test"),
        points: const [
          LatLng(35.130, 136.837),
          LatLng(35.1295, 136.838),
          LatLng(35.131, 136.838),
        ],
        fillColor: Colors.red.withOpacity(0.5),
        strokeColor: Colors.red,
        strokeWidth: 2,
      ),
    };

    final drawPolygonEnabled = ref.watch(drawPolygonEnabledProvider);
    final currentPosition = ref.watch(getUserLocationProvider);
    final _controller = useMemoized(() => Completer<GoogleMapController>(), []);

    final _polygonSet = ref.watch(polygonSetProvider);
    final _polylineSet = useState<HashSet<Polyline>>(HashSet<Polyline>());
    final _latLngList = useState<List<LatLng>>([]);

    final loading = useState(true);

    int? _lastXCoordinate;
    int? _lastYCoordinate;

    void _clearPolygons() {
      _latLngList.value.clear();
      _polylineSet.value.clear();
      _polygonSet.clear();
    }

    void _onPanUpdate(DragUpdateDetails details) async {
      if (ref.read(clearDrawingProvider.state).state) {
        ref.read(clearDrawingProvider.state).state = false;
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
      // x = details.localPosition.dx;
      // y = details.localPosition.dy;

      if (x != null && y != null) {
        int xCoordinate = x.round();
        int yCoordinate = y.round();

        if (_lastXCoordinate != null && _lastYCoordinate != null) {
          var distance = math.sqrt(
              math.pow(xCoordinate - _lastXCoordinate!, 2) +
                  math.pow(yCoordinate - _lastYCoordinate!, 2));
          if (distance > 80.0) return;
        }

        _lastXCoordinate = xCoordinate;
        _lastYCoordinate = yCoordinate;

        ScreenCoordinate screenCoordinate =
            ScreenCoordinate(x: xCoordinate, y: yCoordinate);

        final GoogleMapController controller = await _controller.future;
        LatLng latLng = await controller.getLatLng(screenCoordinate);

        try {
          _latLngList.value.add(latLng);

          _polylineSet.value.removeWhere(
              (polyline) => polyline.polylineId.value == 'user_polyline');
          _polylineSet.value.add(
            Polyline(
              polylineId: const PolylineId('user_polyline'),
              points: _latLngList.value,
              width: 2,
              color: Colors.blue,
            ),
          );
        } catch (e) {
          print(e);
        }
        ref.read(polygonSetProvider.state).state = {..._polygonSet};
      }
    }

    void _onPanEnd(DragEndDetails details) async {
      _lastXCoordinate = null;
      _lastYCoordinate = null;

      _polygonSet
          .removeWhere((polygon) => polygon.polygonId.value == 'user_polygon');
      _polygonSet.add(
        Polygon(
          polygonId: const PolygonId('user_polygon'),
          points: _latLngList.value,
          strokeWidth: 2,
          strokeColor: Colors.blue,
          fillColor: Colors.blue.withOpacity(0.4),
        ),
      );

      ref.read(drawPolygonEnabledProvider.state).update((state) => !state);
    }

    Future<Position> _determinePosition(WidgetRef ref) async {
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
      ref.read(getUserLocationProvider.state).state =
          LatLng(position.latitude, position.longitude);
      return position;
    }

    void _toggleDrawing() {
      _clearPolygons();
      ref.read(drawPolygonEnabledProvider.state).update((state) => !state);
    }

    useEffect(() {
      loading.value = true;
      _determinePosition(ref);
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
      body: loading.value
          ? const CircularProgressIndicator()
          : GestureDetector(
              onPanUpdate: (drawPolygonEnabled) ? _onPanUpdate : null,
              onPanEnd: (drawPolygonEnabled) ? _onPanEnd : null,
              child: GoogleMap(
                mapType: MapType.normal,
                initialCameraPosition: CameraPosition(
                  target: currentPosition,
                  zoom: 14.4746,
                ),
                polygons: _polygonSet,
                polylines: _polylineSet.value,
                myLocationEnabled: true,
                myLocationButtonEnabled: false,
                onMapCreated: (GoogleMapController controller) {
                  _controller.complete(controller);
                },
              ),
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _toggleDrawing,
        backgroundColor: Theme.of(context).primaryColor,
        child: Icon(drawPolygonEnabled ? Icons.cancel : Icons.edit),
      ),
    );
    return Scaffold(
      appBar: AppBar(),
      body: Stack(alignment: Alignment.center, children: <Widget>[
        // ################ マップ ################
        GoogleMap(
          myLocationEnabled: false,
          myLocationButtonEnabled: false,
          initialCameraPosition: navMap.initCamPos,
          mapType: mapType.value,
          onMapCreated: (GoogleMapController controller) async {
            navMap.setController(controller);
            await permission.requestPermission(); // 位置情報の許可取得
            final pos = await Geolocator.getCurrentPosition(
                desiredAccuracy: LOCATION_ACCURACY);
            await navMap.focus(pos.latitude, pos.longitude, 0, 17.0);
          },
          onCameraMoveStarted: () {},
          // markers: navMap.markers,
          polylines: polylines,
          polygons: polygons,
        ),
        // ################ 左右操作ボタン類 ################
        Container(
          alignment: Alignment.center,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 17),
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
                            mapType.value = mapType.value == MapType.normal
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
            padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 17),
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
      ]),
    );
  }
}
