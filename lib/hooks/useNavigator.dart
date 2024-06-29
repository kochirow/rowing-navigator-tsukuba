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
  final timer = useState<Timer?>(null);
  final preProcessTime = useState<DateTime>(DateTime.now());
  final postProcessTime = useState<DateTime>(DateTime.now());
  final geoService = GeoService();

  final LOCATION_ACCURACY = LocationAccuracy.bestForNavigation;
  final POSITION_UPDATE_INTERVAL = 3;

  startNavigation() {
    final message = Message(
        boatId: "around-user-xxxx",
        boatType: 1,
        seatPos: 2,
        lat: 0.1234,
        lng: 0.1234,
        heading: 0.1234,
        timestamp: DateTime.now());
    final messageService = MessageService();
    messageService.sendMessage(message);
  }

  stopNavigation() {}

  watchEnv() {
    final envService = EnvService();
    envStreamSubscription.value = envService.getEnvStream().listen((env) {
      final List<Boat> boats = env['boats'];
      aroundBoats.value = boats;
    });
  }

  updateMyBoat() async {
    final preMyBoat = myBoat.value;
    final Position position =
        await geoService.getCurrentPosition(LOCATION_ACCURACY);
    final double heading = getHeading(
      {"latitude": preMyBoat.lat, "longitude": preMyBoat.lng},
      {"latitude": position.latitude, "longitude": position.longitude},
    );
    myBoat.value = Boat(
      boatId: "my-boat-xxxx",
      boatType: 1,
      seatPos: 2,
      lat: position.latitude,
      lng: position.longitude,
      heading: heading,
      timestamp: position.timestamp,
    );
  }

  watchMyBoat(Function callback) {
    timer.value = Timer.periodic(Duration(seconds: POSITION_UPDATE_INTERVAL),
        (timer) async {
      preProcessTime.value = DateTime.now();
      await updateMyBoat();
      postProcessTime.value = DateTime.now();
      await callback(myBoat.value);
      // TODO: sendMessage
    });
  }

  useEffect(() {
    startNavigation();
    watchEnv();
    return () {
      envStreamSubscription.value?.cancel();
      timer.value?.cancel();
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
    watchMyBoat: watchMyBoat,
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
  final Function watchMyBoat;

  UseNavigator({
    required this.myBoat,
    required this.aroundBoats,
    required this.accuracy,
    required this.preProcessTime,
    required this.postProcessTime,
    required this.startNavigation,
    required this.stopNavigation,
    required this.watchMyBoat,
  });
}
