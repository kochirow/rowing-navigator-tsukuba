import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
/* spellchecker: disable */
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../features/home_map/widgets/BoatStatusCard.dart';
import '../hooks/useNavigator.dart';
import '../hooks/useNavMap.dart';
import '../services/auth_service.dart';
import '../services/permission_service.dart';
import '../types/marker_type.dart';

class HomeMapScreen extends HookConsumerWidget {
  const HomeMapScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final navigator = useNavigator();
    final navMap = useNavMap();
    final permission = PermissionService();
    final auth = AuthService();

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
        newMarkers.add(await navMap.createMarker(
          myBoat.boatId,
          MarkerType.myBoat,
          myBoat.lat,
          myBoat.lng,
          myBoat.heading,
          "自艇",
          "自艇の位置情報\n${myBoat.boatId}",
        ));
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
        await navMap.focus(myBoat.lat, myBoat.lng);
      });
      return null;
    }, [navigator.myBoat, navigator.otherBoats]);

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
              navMap.setController(controller);
              await permission.requestPermission(); // 位置情報の許可取得
              navigator.startNavigation(); // ボートの位置情報を監視
            },
            markers: navMap.markers,
          ),
          // 画面上部に現在位置と時刻を表示
          SizedBox(
              width: double.infinity,
              child: BoatStatusCard(
                myBoat: navigator.myBoat,
                accuracy: navigator.accuracy,
                preProcessTime: navigator.preProcessTime,
                postProcessTime: navigator.postProcessTime,
              )),
        ]),
        floatingActionButton: FloatingActionButton(
          onPressed: () async {
            navMap.focus(navigator.myBoat.lat, navigator.myBoat.lng);
          },
          child: const Icon(Icons.my_location),
        ));
  }
}
