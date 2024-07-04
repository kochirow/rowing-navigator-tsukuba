import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:geolocator/geolocator.dart';
/* spellchecker: disable */
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/widgets/RoundedIconButton.dart';
import 'package:rowing_navigator/features/home_map/widgets/NavButton.dart';

import '../features/home_map/widgets/BoatStatusCard.dart';
import '../hooks/useNavigator.dart';
import '../hooks/useNavMap.dart';
import '../models/nav_config_model.dart';
import '../services/auth_service.dart';
import '../services/permission_service.dart';
import '../types/marker_type.dart';
import '../types/nav_mode_type.dart';

class HomeMapScreen extends HookConsumerWidget {
  const HomeMapScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Hooks
    final navigator = useNavigator();
    final navMap = useNavMap();
    // State
    final showInfo = useState(false);
    // Services
    final permission = PermissionService();
    final auth = AuthService();
    // Constants
    const LOCATION_ACCURACY = LocationAccuracy.bestForNavigation;

    useEffect(() {
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
            myBoat.heading, // 北向き固定の場合はmyBoat.headingを使用
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
        await navMap.setMarkers(newMarkers);
        // 自艇の位置にフォーカス
        if (myBoat != null) {
          await navMap.focus(myBoat.lat, myBoat.lng, myBoat.heading);
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
          onMapCreated: (GoogleMapController controller) async {
            navMap.setController(controller);
            await permission.requestPermission(); // 位置情報の許可取得
            final pos = await navigator.getCurrentPosition(LOCATION_ACCURACY);
            navMap.focus(pos.latitude, pos.longitude, 0.0); // 現在地を中心に表示
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
        // ################ 操作ボタン類 ################
        Container(
          alignment: Alignment.center,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [],
                ),
                Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Container(
                      margin: const EdgeInsets.only(top: 16),
                      child: RoundedIconButton(
                        icon: Icons.article,
                        onPressed: () {
                          showInfo.value = !showInfo.value;
                        },
                      ),
                    ),
                    if (navigator.mode == NavMode.observer)
                      Container(
                        margin: const EdgeInsets.only(top: 16),
                        child: RoundedIconButton(
                          icon: Icons.gps_fixed,
                          onPressed: () async {
                            final pos = await navigator
                                .getCurrentPosition(LOCATION_ACCURACY);
                            navMap.focus(pos.latitude, pos.longitude, 0.0);
                          },
                        ),
                      ),
                    if (navigator.mode == NavMode.navigator)
                      Container(
                        margin: const EdgeInsets.only(top: 16),
                        child: RoundedIconButton(
                          icon: Icons.gps_fixed,
                          onPressed: () async {
                            final pos = await navigator
                                .getCurrentPosition(LOCATION_ACCURACY);
                            navMap.focus(pos.latitude, pos.longitude,
                                navigator.myBoat?.heading ?? 0.0);
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
            padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
            child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (navigator.mode == NavMode.observer)
                    NavButton(
                      label: "Start Nav",
                      onPressed: () async {
                        if (!navMap.isReady || !auth.isSignedIn) return;
                        final userId = auth.currentUser!.uid;
                        final config = NavConfig(
                            boatId: userId,
                            boatType: 0,
                            seatPos: 0,
                            accuracy: LocationAccuracy.bestForNavigation);
                        await navigator.startNavigation(config); // ボートの位置情報を監視
                        print("Navigation started.");
                      },
                    ),
                  if (navigator.mode == NavMode.navigator)
                    NavButton(
                        label: "Stop Nav",
                        onPressed: () async {
                          if (!navMap.isReady || !auth.isSignedIn) return;
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
