import 'dart:async';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:geolocator/geolocator.dart';
import 'package:rowing_navigator/types/safety_level.dart';

import '../hooks/useAlert.dart';
import '../models/boat_model.dart';
import '../models/message_model.dart';
import '../models/nav_config_model.dart';
import '../services/collision_risk_evaluator_service.dart';
import '../services/env_service.dart';
import '../services/geo_service.dart';
import '../services/message_service.dart';
import '../types/alert_type.dart';
import '../types/collision_risk_level.dart';
import '../utils/heading.dart';

UseNavigator useNavigator() {
  final alert = useAlert();
  final config = useState<NavConfig?>(null);
  final safetyLevel = useState<SafetyLevel>(SafetyLevel.safe);
  final myBoat = useState<Boat?>(null);
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
      otherBoats.value = boats
          .where((boat) => config.value != null
              ? (boat.boatId != config.value!.boatId)
              : true)
          .toList();
    });
  }

  getLatestMyBoat() async {
    final preMyBoat = myBoat.value;
    preProcessTime.value = DateTime.now(); // Pre-Process Time
    final Position position =
        await geoService.getCurrentPosition(LOCATION_ACCURACY);
    postProcessTime.value = DateTime.now(); // Post-Process Time
    double heading;
    if (preMyBoat == null) {
      heading = 0.0;
    } else {
      heading = getHeading(
        {"latitude": preMyBoat.lat, "longitude": preMyBoat.lng},
        {"latitude": position.latitude, "longitude": position.longitude},
      );
    }
    return Boat(
      boatId: config.value!.boatId, // 自艇のID
      boatType: 0,
      seatPos: 0,
      lat: position.latitude,
      lng: position.longitude,
      heading: heading,
      timestamp: position.timestamp,
    );
  }

  getSafetyLevelFrom(CollisionRiskLevel riskLevel) {
    switch (riskLevel) {
      case CollisionRiskLevel.lv1:
        return SafetyLevel.safe;
      case CollisionRiskLevel.lv2:
        return SafetyLevel.caution;
      case CollisionRiskLevel.lv3:
        return SafetyLevel.warning;
      case CollisionRiskLevel.lv4:
        return SafetyLevel.critical;
      case CollisionRiskLevel.lv5:
        return SafetyLevel.emergency;
      default:
        return SafetyLevel.emergency;
    }
  }

  getAlertTypeFrom(SafetyLevel safetyLevel) {
    switch (safetyLevel) {
      case SafetyLevel.caution:
        return AlertType.caution;
      case SafetyLevel.warning:
        return AlertType.warning;
      case SafetyLevel.critical:
        return AlertType.critical;
      case SafetyLevel.emergency:
        return AlertType.emergency;
      default:
        return AlertType.emergency;
    }
  }

  navigate() async {
    // ======== Update MyBoat Status ========
    final latestMyBoat = await getLatestMyBoat();
    myBoat.value = latestMyBoat;

    // ======== Send Message ========
    final message = Message.fromBoat(latestMyBoat);
    final messageService = MessageService();
    messageService.sendMessage(message);

    // ======== Evaluate Collision Risk ========
    final evaluator = CollisionRiskEvaluatorService();
    final riskLevel = evaluator.evaluateRisk(
      latestMyBoat,
      otherBoats.value,
    );
    final safetyLevel_ = getSafetyLevelFrom(riskLevel);
    safetyLevel.value = safetyLevel_;

    // ======== Alert ========
    // useEffectにて実装
  }

  startNavigation(NavConfig config_) async {
    // メッセージを初期化
    final messageService = MessageService();
    await messageService.clearMessage(config_.boatId);
    // ナビゲーションの設定を保存
    config.value = config_;
    // ナビゲーションを開始
    await navigate();
    watchTimer.value = Timer.periodic(
        Duration(seconds: POSITION_UPDATE_INTERVAL), (timer) async {
      await navigate();
    });
  }

  stopNavigation() async {
    watchTimer.value?.cancel();
    final messageService = MessageService();
    await messageService.clearMessage(config.value!.boatId);
    myBoat.value = null;
    config.value = null;
    safetyLevel.value = SafetyLevel.safe;
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
  final Boat? myBoat;
  final List<Boat> otherBoats;
  final LocationAccuracy accuracy;
  final DateTime preProcessTime;
  final DateTime postProcessTime;
  final Future<void> Function(NavConfig config) startNavigation;
  final Future<void> Function() stopNavigation;

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
