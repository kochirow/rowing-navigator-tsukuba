import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:geolocator/geolocator.dart';
/* spellchecker: disable */
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/services/ship_domain_service.dart';

import '../config/risk_evaluation_config.dart';
import '../features/home_map/widgets/BoatStatusCard.dart';
import '../features/home_map/widgets/MapTypeSwitcher.dart';
import '../features/home_map/widgets/RoundedButton.dart';
import '../hooks/useTracking.dart';
import '../services/collision_risk_evaluator_service.dart';
import '../types/tracking_mode.dart';
import '../widgets/RoundedIconButton.dart';
import '../hooks/useNavigator.dart';
import '../hooks/useNavMap.dart';
import '../models/nav_config_model.dart';
import '../services/auth_service.dart';
import '../services/permission_service.dart';
import '../types/marker_type.dart';
import '../types/nav_mode.dart';
import 'area_setting_screen.dart';

class HomeMapScreen extends HookConsumerWidget {
  const HomeMapScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Hooks
    final navigator = useNavigator();
    final navMap = useNavMap();
    final tracking = useTracking();
    // State
    final loading = useState(true);
    final initLatLng = useState<LatLng?>(null);
    final showInfo = useState(false);
    final shipDomains = useState<Set<Polygon>>({});
    final obstacles = useState<Set<Polygon>>({});
    // Services
    final permission = PermissionService();
    final auth = AuthService();
    // Constants
    const LOCATION_ACCURACY = LocationAccuracy.bestForNavigation;
    const DEFAULT_ZOOM_LEVEL = 17.0;

    focusP14y(double lat, double lng, double heading) async {
      // Focus programatically
      tracking.setProgFlag(true); // プログラムによる操作フラグを立てる
      final currentZoomLevel = await navMap.getZoomLevel();
      final zoomLevel = currentZoomLevel > DEFAULT_ZOOM_LEVEL
          ? currentZoomLevel
          : DEFAULT_ZOOM_LEVEL;
      await navMap.focus(lat, lng, heading, zoomLevel);
    }

    // ##########################
    // ログイン処理／初期位置の取得
    // ##########################
    useEffect(() {
      Future(() async {
        loading.value = true;
        if (!auth.isSignedIn) {
          await auth.signInAnonymously();
          print("Signed in with temporary account.");
          print("UID: ${auth.currentUser?.uid}");
        } else {
          print("Already signed in.");
          print("UID: ${auth.currentUser?.uid}");
        }
        // 初期位置の取得
        navMap.setMapType(MapType.normal);
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
    // 自艇および他艇を描画
    // ##########################
    useEffect(() {
      if (!navMap.isReady.value) return;
      Future(() async {
        final newMarkers = <Marker>{};
        // 自艇のマーカーを作成
        final myBoat = navigator.myBoat.value;
        if (myBoat != null) {
          newMarkers.add(await navMap.createMarker(
            myBoat.boatId,
            MarkerType.myBoat,
            myBoat.lat,
            myBoat.lng,
            myBoat.heading,
            "自艇",
            "自艇の位置情報\n${myBoat.boatId}\nBoatType: ${myBoat.boatType}",
          ));
        }
        // 他艇のマーカーを作成
        final otherBoats = navigator.otherBoats.value;
        for (final boat in otherBoats) {
          newMarkers.add(await navMap.createMarker(
            boat.boatId,
            MarkerType.otherBoat,
            boat.lat,
            boat.lng,
            boat.heading,
            "他艇",
            "他艇の位置情報\n${boat.boatId}\nBoatType: ${boat.boatType}",
          ));
        }
        // マーカーを更新
        navMap.setMarkers(newMarkers);
        // ナビゲーションモードかつトラッキングモードなら自艇を追跡
        if (myBoat != null && tracking.mode.value == TrackingMode.track) {
          focusP14y(myBoat.lat, myBoat.lng, myBoat.heading);
        }
      });

      // ###########################
      // 船舶領域を可視化
      // ###########################
      final shipDomainService = ShipDomainService();
      final evalService = CollisionRiskEvaluatorService();
      // 全艇の船舶領域を取得
      final myBoat = navigator.myBoat.value;
      final allBoats = [
        if (myBoat != null) myBoat,
        ...navigator.otherBoats.value
      ];
      Set<Polygon> newShipDomains = {};
      for (final boat in allBoats) {
        const speed = 2.0; // for development
        final stoppingDistance = evalService.getStoppingDistance(boat);
        for (double t = 0; speed * t <= stoppingDistance; t += deltaTime) {
          final futureBoat = evalService.predictPosition(boat, t);
          final futureDomains = shipDomainService.getShipDomains(futureBoat);
          List<Polygon> domains = futureDomains.allDomains;
          domains = domains.map((domain) {
            return Polygon(
              polygonId:
                  PolygonId("${domain.polygonId.value}_${boat.boatId}_$t"),
              points: domain.points,
              strokeWidth: 0,
              fillColor: domain.fillColor
                  .withOpacity((1.0 - t / stoppingDistance) * 0.1 + 0.1),
            );
          }).toList();
          newShipDomains.addAll(domains);
        }
      }
      shipDomains.value = newShipDomains;
      return null;
    }, [navigator.myBoat.value, navigator.otherBoats.value]);

    // ##########################
    // 障害物を描画
    // ##########################
    useEffect(() {
      // 障害物のポリゴンを描画
      final newObstacles = <Polygon>{};
      for (final obstacle in navigator.obstacles.value) {
        final points = obstacle.points
            .map((point) => LatLng(point.latitude, point.longitude))
            .toList();
        newObstacles.add(Polygon(
          polygonId: PolygonId(obstacle.id),
          points: points,
          strokeWidth: 0,
          fillColor: Colors.red.withOpacity(0.5),
        ));
      }
      obstacles.value = newObstacles;
      return null;
    }, [navigator.obstacles.value]);

    // ##########################
    // Polygonsの統合
    // ##########################
    useEffect(() {
      final newPolygons = {...shipDomains.value, ...obstacles.value};
      navMap.setPolygons(newPolygons);
      return null;
    }, [shipDomains.value, obstacles.value]);

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
          : Stack(alignment: Alignment.center, children: <Widget>[
              // ################ マップ ################
              GoogleMap(
                myLocationEnabled: navigator.myBoat.value == null,
                myLocationButtonEnabled: false,
                initialCameraPosition: CameraPosition(
                  target: initLatLng.value!,
                  zoom: DEFAULT_ZOOM_LEVEL,
                ),
                mapType: navMap.mapType.value,
                onMapCreated: (GoogleMapController controller) async {
                  navMap.setController(controller);
                },
                onCameraMoveStarted: () {
                  // プログラムによる操作でない場合はユーザによる操作とみなしてトラッキングモードを解除
                  if (!tracking.progFlag.value) {
                    tracking.setMode(TrackingMode.untrack);
                  }
                  // プログラムによる操作フラグを解除
                  tracking.setProgFlag(false);
                },
                markers: navMap.markers.value,
                polygons: navMap.polygons.value,
              ),
              // ################ 艇情報カード ################
              Column(
                children: [
                  if (showInfo.value)
                    SizedBox(
                        width: double.infinity,
                        child: BoatStatusCard(
                          myBoat: navigator.myBoat.value,
                          config: navigator.config.value,
                          preProcessTime: navigator.preProcessTime.value,
                          postProcessTime: navigator.postProcessTime.value,
                        ))
                ],
              ),
              // ################ 左右操作ボタン類 ################
              Container(
                alignment: Alignment.center,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 48, horizontal: 17),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // ################ 左側 ################
                      Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          MapTypeSwitcher(
                            mapType: navMap.mapType.value,
                            onTap: () {
                              navMap.setMapType(
                                  navMap.mapType.value == MapType.normal
                                      ? MapType.hybrid
                                      : MapType.normal);
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
                          if (navigator.mode.value == NavMode.observer)
                            Container(
                              margin: const EdgeInsets.only(top: 17),
                              child: RoundedIconButton(
                                icon: Icons.map,
                                onPressed: () {
                                  Navigator.push(context,
                                      MaterialPageRoute(builder: (context) {
                                    return const AreaSettingScreen();
                                  }));
                                },
                              ),
                            ),
                          if (navigator.mode.value == NavMode.observer)
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
                          if (navigator.mode.value == NavMode.navigator)
                            Container(
                              margin: const EdgeInsets.only(top: 17),
                              child: RoundedIconButton(
                                icon: Icons.navigation,
                                angle: 45,
                                onPressed: () async {
                                  // トラッキングモードに切り替え
                                  tracking.setMode(TrackingMode.track);
                                  // 現在位置をフォーカス
                                  final myBoat = navigator.myBoat.value;
                                  if (myBoat != null) {
                                    focusP14y(myBoat.lat, myBoat.lng,
                                        navigator.myBoat.value?.heading ?? 0.0);
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
                  padding:
                      const EdgeInsets.symmetric(vertical: 48, horizontal: 17),
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if (navigator.mode.value == NavMode.observer)
                          RoundedButton(
                            label: "Start Nav",
                            onPressed: () async {
                              if (!navMap.isReady.value || !auth.isSignedIn)
                                return;
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
                              final myBoat = navigator.myBoat.value;
                              if (myBoat != null) {
                                focusP14y(myBoat.lat, myBoat.lng,
                                    navigator.myBoat.value?.heading ?? 0.0);
                              }
                              print("Navigation started.");
                            },
                          ),
                        if (navigator.mode.value == NavMode.navigator)
                          RoundedButton(
                              label: "Stop Nav",
                              onPressed: () async {
                                if (!navMap.isReady.value || !auth.isSignedIn)
                                  return;
                                // 現在位置をフォーカス
                                final myBoat = navigator.myBoat.value;
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
