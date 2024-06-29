import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
/* spellchecker: disable */
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../features/home_map/widgets/BoatStatusCard.dart';
import '../hooks/useNavigator.dart';
import '../hooks/useNavMap.dart';
import '../models/boat_model.dart';
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

    void updateNavMapHandler(Boat myBoat) async {
      navMap.setMarker(
        await navMap.createMarker(
          "my_boat",
          MarkerType.myBoat,
          myBoat.lat,
          myBoat.lng,
          myBoat.heading,
          "ボート",
          "ボートの位置情報",
        ),
      );
      navMap.focus(myBoat.lat, myBoat.lng);
    }

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
              navigator.watchMyBoat(updateNavMapHandler); // ボートの位置情報を監視
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
          onPressed: () {
            navMap.focus(navigator.myBoat.lat, navigator.myBoat.lng);
          },
          child: const Icon(Icons.my_location),
        ));
  }
}
