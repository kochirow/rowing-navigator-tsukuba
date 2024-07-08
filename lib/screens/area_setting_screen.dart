import 'dart:async';
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
          markers: navMap.markers,
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
