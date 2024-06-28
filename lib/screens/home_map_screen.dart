import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
/* spellchecker: disable */
import 'package:geolocator/geolocator.dart';

import '../hooks/useNavigator.dart';
import '../services/auth_service.dart';
import '../services/permission_service.dart';
import '../services/navigation_service.dart';
import '../services/geo_service.dart';
import '../utils/image2icon.dart';
import '../utils/heading.dart';

class HomeMapScreen extends HookConsumerWidget {
  const HomeMapScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mapController = useState<GoogleMapController?>(null);
    final currentPosition = useState<Position?>(null);
    final currentHeading = useState<double>(0);
    final markers = useState<Set<Marker>>({});
    final timer = useState<Timer?>(null);
    final preProcessTime = useState<DateTime>(DateTime.now());
    final postProcessTime = useState<DateTime>(DateTime.now());
    final permission = PermissionService();
    final auth = AuthService();
    final nav = NavigationService();
    final geo = GeoService();

    final LOCATION_ACCURACY = LocationAccuracy.bestForNavigation;
    final POSITION_UPDATE_INTERVAL = 3;

    final initialCameraPosition = const CameraPosition(
      target: LatLng(35.681236, 139.767125), // 東京駅
      zoom: 16.0,
    );

    // =============================================
    // マーカーを更新
    // =============================================
    void updateMarkers() async {
      final zoomLevel = await mapController.value!.getZoomLevel();
      final iconSize = (zoomLevel * 4).toInt(); // ZoomLevelに応じてiconSizeを変更
      final icon = await getBitmapDescriptorFromAssetBytes(
          'assets/icons/ship.png', iconSize);
      markers.value.add(
        Marker(
          markerId: const MarkerId("current_location"),
          // markerId: MarkerId(DateTime.now().toString()),
          position: LatLng(
            currentPosition.value!.latitude,
            currentPosition.value!.longitude,
          ),
          icon: icon,
          infoWindow: const InfoWindow(title: "タイトル", snippet: "詳細情報"),
          anchor: const Offset(0.5, 0.5), // 回転軸をアイコンの中央に設定
          // MEMO: 向き情報の取得方法は要検討
          rotation: currentHeading.value, // 向きを設定
        ),
      );
    }

    // =============================================
    // 現在地にカメラを移
    // =============================================
    void focusCurrentPosition() async {
      await mapController.value!.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: LatLng(currentPosition.value!.latitude,
                currentPosition.value!.longitude),
            zoom: await mapController.value!.getZoomLevel(),
          ),
        ),
      );
    }

    // =============================================
    // 現在地を更新
    // =============================================
    void updateCurrentPosition() async {
      final _preProcessTime = DateTime.now();
      final prePosition = currentPosition.value!;
      final Position position = await geo.getCurrentPosition(LOCATION_ACCURACY);
      currentPosition.value = position;
      currentHeading.value = getHeading(
        prePosition,
        position,
      );
      updateMarkers();
      focusCurrentPosition();
      preProcessTime.value = _preProcessTime;
      postProcessTime.value = DateTime.now();
      await nav.updateNavigation(
        auth.currentUser!.uid,
        position.latitude,
        position.longitude,
      );
    }

    // =============================================
    // 位置情報の定期更新を開始
    // =============================================
    void startPeriodicPositionUpdate() {
      timer.value =
          Timer.periodic(Duration(seconds: POSITION_UPDATE_INTERVAL), (timer) {
        updateCurrentPosition();
      });
    }

    // =============================================
    // LifeCycles
    // =============================================
    useEffect(() {
      currentPosition.value = Position(
        latitude: 35.681236,
        longitude: 139.767125,
        accuracy: 0,
        altitude: 0,
        altitudeAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        timestamp: DateTime.now(),
      );
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
      return () {
        mapController.value?.dispose();
        timer.value?.cancel();
      };
    }, []);

    return Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          title: null,
        ),
        body: Stack(alignment: Alignment.topCenter, children: <Widget>[
          GoogleMap(
            myLocationEnabled: false,
            myLocationButtonEnabled: false,
            initialCameraPosition: initialCameraPosition,
            onMapCreated: (GoogleMapController controller) async {
              await Future.delayed(
                  const Duration(microseconds: 1)); // 中心座標がずれるバグを防ぐため1ms待機
              mapController.value = controller;
              await permission.requestPermission(); // 位置情報の許可取得
              updateCurrentPosition(); // 現在地を取得
              startPeriodicPositionUpdate(); // 位置情報の定期更新を開始
            },
            markers: markers.value,
          ),
          // 画面上部に現在位置と時刻を表示
          SizedBox(
              width: double.infinity,
              child: Card(
                margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                color: Colors.white.withOpacity(0.9),
                elevation: 0,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    "緯度: ${currentPosition.value!.latitude.toStringAsFixed(14)}\n"
                    "経度: ${currentPosition.value!.longitude.toStringAsFixed(14)}\n"
                    "精度: ${LOCATION_ACCURACY.name.toString()} ${currentPosition.value!.accuracy.toString()}m\n"
                    "開始時刻: ${preProcessTime.value.toLocal().toString()}\n"
                    "確定時刻: ${currentPosition.value!.timestamp.toLocal().toString()}\n"
                    "終了時刻: ${postProcessTime.value.toLocal().toString()}\n"
                    "表示時刻: ${DateTime.now().toLocal().toString()}\n"
                    "確定-開始: ${(currentPosition.value!.timestamp.difference(preProcessTime.value)).toString()}秒\n"
                    "方位角: ${currentHeading.value.toStringAsFixed(1)}",
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              )),
        ]),
        floatingActionButton: FloatingActionButton(
          onPressed: () {
            focusCurrentPosition(); // 現在地にカメラを移動
          },
          child: const Icon(Icons.my_location),
        ));
  }
}
