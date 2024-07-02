import 'dart:async';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:geolocator/geolocator.dart';
import 'package:rowing_navigator/types/safety_level.dart';

import '../hooks/useAlert.dart';
import '../models/boat_model.dart';
import '../services/collision_risk_evaluator_service.dart';
import '../services/env_service.dart';
import '../services/geo_service.dart';
import '../services/message_service.dart';
import '../types/alert_type.dart';
import '../types/collision_risk_level.dart';
import '../utils/heading.dart';

UseNavigator useNavigator() {
  final alert = useAlert();
  final safetyLevel = useState<SafetyLevel>(SafetyLevel.safe);
  final myBoat = useState<Boat>(Boat.init);
  final otherBoats = useState<List<Boat>>([]);
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
      otherBoats.value =
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

  getSafetyLevelFrom(CollisionRiskLevel riskLevel) {
    SafetyLevel safetyLevel = SafetyLevel.safe;
    switch (riskLevel) {
      case CollisionRiskLevel.lv1:
        safetyLevel = SafetyLevel.safe;
        break;
      case CollisionRiskLevel.lv2:
        safetyLevel = SafetyLevel.caution;
        break;
      case CollisionRiskLevel.lv3:
        safetyLevel = SafetyLevel.warning;
        break;
      case CollisionRiskLevel.lv4:
        safetyLevel = SafetyLevel.danger;
        break;
      case CollisionRiskLevel.lv5:
        safetyLevel = SafetyLevel.emergency;
    }
    return safetyLevel;
  }

  getAlertTypeFrom(SafetyLevel safetyLevel) {
    switch (safetyLevel) {
      case SafetyLevel.caution:
        return AlertType.caution;
      case SafetyLevel.warning:
        return AlertType.warning;
      case SafetyLevel.danger:
        return AlertType.danger;
      case SafetyLevel.critical:
        return AlertType.critical;
      case SafetyLevel.emergency:
        return AlertType.emergency;
      default:
        return AlertType.emergency;
    }
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

      // ======== Evaluate Collision Risk ========
      final evaluator = CollisionRiskEvaluatorService();
      final riskLevel = evaluator.evaluateRisk(
        myBoat.value,
        otherBoats.value,
      );
      final safetyLevel_ = getSafetyLevelFrom(riskLevel);
      safetyLevel.value = safetyLevel_;

      // ======== Alert ========
      // useEffectにて実装
    });
  }

  stopNavigation() {
    watchTimer.value?.cancel();
    final messageService = MessageService();
    messageService.clearMessage("my-boat");
    // myBoat.value = null; // TODO: Optional対応後に追加
  }

  useEffect(() {
    watchEnv();
    return () {
      envStreamSubscription.value?.cancel();
      watchTimer.value?.cancel();
    };
  }, []);

  useEffect(() {
    // ======== Alert ========
    final safetyLevel_ = safetyLevel.value;
    if (safetyLevel_ == SafetyLevel.safe) {
      alert.stop();
    } else {
      final alertType = getAlertTypeFrom(safetyLevel_);
      alert.play(alertType); // SafetyLevelに応じたAlertを再生
    }
    print("Safety Level Changed: $safetyLevel_");
    return null;
  }, [safetyLevel.value]);

  return UseNavigator(
    myBoat: myBoat.value,
    otherBoats: otherBoats.value,
    accuracy: LOCATION_ACCURACY,
    preProcessTime: preProcessTime.value,
    postProcessTime: postProcessTime.value,
    startNavigation: startNavigation,
    stopNavigation: stopNavigation,
  );
}

class UseNavigator {
  final Boat myBoat;
  final List<Boat> otherBoats;
  final LocationAccuracy accuracy;
  final DateTime preProcessTime;
  final DateTime postProcessTime;
  final Function startNavigation;
  final Function stopNavigation;

  UseNavigator({
    required this.myBoat,
    required this.otherBoats,
    required this.accuracy,
    required this.preProcessTime,
    required this.postProcessTime,
    required this.startNavigation,
    required this.stopNavigation,
  });
}
