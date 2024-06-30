import 'dart:async';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:geolocator/geolocator.dart';
import 'package:rowing_navigator/models/message_model.dart';

import '../models/boat_model.dart';
import '../services/env_service.dart';
import '../services/geo_service.dart';
import '../services/message_service.dart';
import '../utils/heading.dart';

UseNavigator useNavigator() {
  final myBoat = useState<Boat>(Boat.init);
  final aroundBoats = useState<List<Boat>>([]);
  final envStreamSubscription = useState<StreamSubscription?>(null);
  final watchTimer = useState<Timer?>(null);
  final preProcessTime = useState<DateTime>(DateTime.now());
  final postProcessTime = useState<DateTime>(DateTime.now());
  final geoService = GeoService();

  final LOCATION_ACCURACY = LocationAccuracy.bestForNavigation;
  final POSITION_UPDATE_INTERVAL = 3;

  watchEnv() {
    final envService = EnvService();
    envStreamSubscription.value = envService.getEnvStream().listen((env) {
      final List<Boat> boats = env['boats'];
      aroundBoats.value =
          boats.where((boat) => boat.boatId != "my-boat").toList();
    });
  }

  getLatestMyBoat() async {
    final preMyBoat = myBoat.value;
    preProcessTime.value = DateTime.now(); // Pre-Process Time
    final Position position =
        await geoService.getCurrentPosition(LOCATION_ACCURACY);
    postProcessTime.value = DateTime.now(); // Post-Process Time
    final double heading = getHeading(
      {"latitude": preMyBoat.lat, "longitude": preMyBoat.lng},
      {"latitude": position.latitude, "longitude": position.longitude},
    );
    return Boat(
      boatId: "my-boat",
      boatType: 0,
      seatPos: 0,
      lat: position.latitude,
      lng: position.longitude,
      heading: heading,
      timestamp: position.timestamp,
    );
  }

  startNavigation() {
    watchTimer.value = Timer.periodic(
        Duration(seconds: POSITION_UPDATE_INTERVAL), (timer) async {
      // ======== Update MyBoat Status ========
      final latestMyBoat = await getLatestMyBoat();
      myBoat.value = latestMyBoat;
      // ======== Send Message ========
      // final message = Message.fromBoat(myBoat.value);
      // final messageService = MessageService();
      // messageService.sendMessage(message);
      // ======== Collision Detection ========
      const flag = true;
      if (flag) {
        // ======== Alert ========
      }
    });
  }

  stopNavigation() {
    watchTimer.value?.cancel();
    final messageService = MessageService();
    messageService.clearMessage("my-boat");
  }

  useEffect(() {
    watchEnv();
    return () {
      envStreamSubscription.value?.cancel();
      watchTimer.value?.cancel();
    };
  }, []);

  return UseNavigator(
    myBoat: myBoat.value,
    aroundBoats: aroundBoats.value,
    accuracy: LOCATION_ACCURACY,
    preProcessTime: preProcessTime.value,
    postProcessTime: postProcessTime.value,
    startNavigation: startNavigation,
    stopNavigation: stopNavigation,
  );
}

class UseNavigator {
  final Boat myBoat;
  final List<Boat> aroundBoats;
  final LocationAccuracy accuracy;
  final DateTime preProcessTime;
  final DateTime postProcessTime;
  final Function startNavigation;
  final Function stopNavigation;

  UseNavigator({
    required this.myBoat,
    required this.aroundBoats,
    required this.accuracy,
    required this.preProcessTime,
    required this.postProcessTime,
    required this.startNavigation,
    required this.stopNavigation,
  });
}
