import 'dart:async';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:rowing_navigator/models/message_model.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/boat_model.dart';
import '../services/env_service.dart';
import '../services/message_service.dart';

Map<String, dynamic> useNavigator() {
  final myBoat = useState<Boat?>(null);
  final aroundBoats = useState<List<Boat>>([]);
  final navMap = useState({});
  final envStreamSubscription = useState<StreamSubscription?>(null);

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

  useEffect(() {
    startNavigation();
    watchEnv();
    return () {
      envStreamSubscription.value?.cancel();
    };
  }, []);

  return {
    'myBoat': myBoat,
    'aroundBoats': aroundBoats,
    'navMap': navMap,
    'startNavigation': startNavigation,
    'stopNavigation': stopNavigation,
  };
}
