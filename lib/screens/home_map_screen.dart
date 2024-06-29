import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
/* spellchecker: disable */
import 'package:geolocator/geolocator.dart';

import '../hooks/useNavigator.dart';
import '../hooks/useNavMap.dart';
import '../services/auth_service.dart';
import '../services/permission_service.dart';
import '../services/navigation_service.dart';
import '../services/geo_service.dart';
import '../types/marker_type.dart';
import '../utils/heading.dart';

class HomeMapScreen extends HookConsumerWidget {
  const HomeMapScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentPosition = useState<Position?>(null);
    final currentHeading = useState<double>(0);
    final timer = useState<Timer?>(null);
    final preProcessTime = useState<DateTime>(DateTime.now());
    final postProcessTime = useState<DateTime>(DateTime.now());
    final permission = PermissionService();
    final auth = AuthService();
    final nav = NavigationService();
    final geo = GeoService();
    final navigator = useNavigator();
    final myBoat = navigator['myBoat'];
    final aroundBoats = navigator['aroundBoats'];
    final navMap = useNavMap();

    final LOCATION_ACCURACY = LocationAccuracy.bestForNavigation;
    final POSITION_UPDATE_INTERVAL = 3;

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
      navMap.setMarker(
        await navMap.createMarker(
          "current_location",
          MarkerType.myBoat,
          position.latitude,
          position.longitude,
          currentHeading.value,
          "タイトル",
          "詳細情報",
        ),
      );
      navMap.focus(position.latitude, position.longitude);
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
            initialCameraPosition: navMap.initCamPos,
            onMapCreated: (GoogleMapController controller) async {
              await Future.delayed(
                  const Duration(microseconds: 1)); // 中心座標がずれるバグを防ぐため1ms待機
              navMap.setController(controller);
              await permission.requestPermission(); // 位置情報の許可取得
              updateCurrentPosition(); // 現在地を取得
              startPeriodicPositionUpdate(); // 位置情報の定期更新を開始
            },
            markers: navMap.markers,
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
                    "ボート: ${myBoat.value}\n"
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
            navMap.focus(
              currentPosition.value!.latitude,
              currentPosition.value!.longitude,
            );
          },
          child: const Icon(Icons.my_location),
        ));
  }
}
