import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:geolocator/geolocator.dart';
/* spellchecker: disable */
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../features/home_map/widgets/BoatStatusCard.dart';
import '../features/home_map/widgets/MapTypeSwitcher.dart';
import '../features/home_map/widgets/NavButton.dart';
import '../hooks/useTracking.dart';
import '../types/tracking_mode.dart';
import '../widgets/RoundedIconButton.dart';
import '../hooks/useNavigator.dart';
import '../hooks/useNavMap.dart';
import '../models/nav_config_model.dart';
import '../services/auth_service.dart';
import '../services/permission_service.dart';
import '../types/marker_type.dart';
import '../types/nav_mode.dart';

class HomeMapScreen extends HookConsumerWidget {
  const HomeMapScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Hooks
    final navigator = useNavigator();
    final navMap = useNavMap();
    final tracking = useTracking();
    // State
    final showInfo = useState(false);
    final mapType = useState(MapType.normal);
    // Services
    final permission = PermissionService();
    final auth = AuthService();
    // Constants
    const LOCATION_ACCURACY = LocationAccuracy.bestForNavigation;
    const LEAST_ZOOM_LEVEL = 17.0;

    focusP14y(double lat, double lng, double heading) async {
      // Focus programatically
      tracking.setProgFlag(true); // プログラムによる操作フラグを立てる
      final currentZoomLevel = await navMap.getZoomLevel();
      final zoomLevel = currentZoomLevel > LEAST_ZOOM_LEVEL
          ? currentZoomLevel
          : LEAST_ZOOM_LEVEL;
      await navMap.focus(lat, lng, heading, zoomLevel);
    }

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

    // 自艇および他艇の状態を監視し、変更があればマーカーを再描画
    useEffect(() {
      if (!navMap.isReady) return;
      Future(() async {
        final newMarkers = <Marker>{};
        // 自艇のマーカーを作成
        final myBoat = navigator.myBoat;
        if (myBoat != null) {
          newMarkers.add(await navMap.createMarker(
            myBoat.boatId,
            MarkerType.myBoat,
            myBoat.lat,
            myBoat.lng,
            myBoat.heading,
            "自艇",
            "自艇の位置情報\n${myBoat.boatId}",
          ));
        }
        // 他艇のマーカーを作成
        final otherBoats = navigator.otherBoats;
        for (final boat in otherBoats) {
          newMarkers.add(await navMap.createMarker(
            boat.boatId,
            MarkerType.otherBoat,
            boat.lat,
            boat.lng,
            boat.heading,
            "他艇",
            "他艇の位置情報\n${boat.boatId}",
          ));
        }
        // マーカーを更新
        navMap.setMarkers(newMarkers);
        // ナビゲーションモードかつトラッキングモードなら自艇を追跡
        if (myBoat != null && tracking.mode == TrackingMode.track) {
          focusP14y(myBoat.lat, myBoat.lng, myBoat.heading);
        }
      });
      return null;
    }, [navigator.myBoat, navigator.otherBoats]);

    return Scaffold(
      appBar: AppBar(),
      body: Stack(alignment: Alignment.center, children: <Widget>[
        // ################ マップ ################
        GoogleMap(
          myLocationEnabled: navigator.myBoat == null,
          myLocationButtonEnabled: false,
          initialCameraPosition: navMap.initCamPos,
          mapType: mapType.value,
          onMapCreated: (GoogleMapController controller) async {
            navMap.setController(controller);
            await permission.requestPermission(); // 位置情報の許可取得
            final pos = await navigator.getCurrentPosition(LOCATION_ACCURACY);
            focusP14y(pos.latitude, pos.longitude, 0.0); // 現在地を中心に表示
          },
          onCameraMoveStarted: () {
            // プログラムによる操作でない場合はユーザによる操作とみなしてトラッキングモードを解除
            if (!tracking.progFlag) {
              tracking.setMode(TrackingMode.untrack);
            }
            // プログラムによる操作フラグを解除
            tracking.setProgFlag(false);
          },
          markers: navMap.markers,
        ),
        // ################ 艇情報カード ################
        Column(
          children: [
            if (showInfo.value)
              SizedBox(
                  width: double.infinity,
                  child: BoatStatusCard(
                    myBoat: navigator.myBoat,
                    config: navigator.config,
                    preProcessTime: navigator.preProcessTime,
                    postProcessTime: navigator.postProcessTime,
                  ))
          ],
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
                    MapTypeSwitcher(
                      mapType: mapType.value,
                      onTap: () {
                        mapType.value = mapType.value == MapType.normal
                            ? MapType.hybrid
                            : MapType.normal;
                      },
                    ),
                  ],
                ),
                // ################ 右側 ################
                Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Container(
                      margin: const EdgeInsets.only(top: 17),
                      child: RoundedIconButton(
                        icon: Icons.article,
                        onPressed: () {
                          showInfo.value = !showInfo.value;
                        },
                      ),
                    ),
                    if (navigator.mode == NavMode.observer)
                      Container(
                        margin: const EdgeInsets.only(top: 17),
                        child: RoundedIconButton(
                          icon: Icons.gps_fixed,
                          onPressed: () async {
                            // 現在地をフォーカス
                            final pos = await navigator
                                .getCurrentPosition(LOCATION_ACCURACY);
                            focusP14y(pos.latitude, pos.longitude, 0.0);
                          },
                        ),
                      ),
                    if (navigator.mode == NavMode.navigator)
                      Container(
                        margin: const EdgeInsets.only(top: 17),
                        child: RoundedIconButton(
                          icon: Icons.gps_fixed,
                          onPressed: () async {
                            // トラッキングモードに切り替え
                            tracking.setMode(TrackingMode.track);
                            // 現在位置をフォーカス
                            final myBoat = navigator.myBoat;
                            if (myBoat != null) {
                              focusP14y(myBoat.lat, myBoat.lng,
                                  navigator.myBoat?.heading ?? 0.0);
                            }
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
            padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 17),
            child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (navigator.mode == NavMode.observer)
                    NavButton(
                      label: "Start Nav",
                      onPressed: () async {
                        if (!navMap.isReady || !auth.isSignedIn) return;
                        // ナビゲーションを開始
                        final userId = auth.currentUser!.uid;
                        final config = NavConfig(
                            boatId: userId,
                            boatType: 0,
                            seatPos: 0,
                            accuracy: LocationAccuracy.bestForNavigation);
                        await navigator.startNavigation(config);
                        // トラッキングモードに切り替え
                        tracking.setMode(TrackingMode.track);
                        // 現在位置をフォーカス
                        final myBoat = navigator.myBoat;
                        if (myBoat != null) {
                          focusP14y(myBoat.lat, myBoat.lng,
                              navigator.myBoat?.heading ?? 0.0);
                        }
                        print("Navigation started.");
                      },
                    ),
                  if (navigator.mode == NavMode.navigator)
                    NavButton(
                        label: "Stop Nav",
                        onPressed: () async {
                          if (!navMap.isReady || !auth.isSignedIn) return;
                          // 現在位置をフォーカス
                          final myBoat = navigator.myBoat;
                          if (myBoat != null) {
                            focusP14y(myBoat.lat, myBoat.lng, 0.0);
                          }
                          // ナビゲーションを停止
                          await navigator.stopNavigation();
                          print("Navigation stopped.");
                        }),
                ]),
          ),
        ),
      ]),
    );
  }
}
