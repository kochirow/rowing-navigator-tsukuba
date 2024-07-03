import 'dart:async';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:geolocator/geolocator.dart';

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
import '../types/nav_mode_type.dart';
import '../types/safety_level.dart';
import '../utils/heading.dart';

UseNavigator useNavigator() {
  // Navigator
  final config = useState<NavConfig?>(null);
  final mode = useState<NavMode>(NavMode.observer);
  final safetyLevel = useState<SafetyLevel>(SafetyLevel.safe);
  final myBoat = useState<Boat?>(null);
  final otherBoats = useState<List<Boat>>([]);
  // Streams
  final envStreamSubscription = useState<StreamSubscription?>(null);
  final watchTimer = useState<Timer?>(null);
  // Time
  final preProcessTime = useState<DateTime>(DateTime.now());
  final postProcessTime = useState<DateTime>(DateTime.now());
  // Hooks
  final alert = useAlert();
  // Services
  final geoService = GeoService();

  // Constants
  final POSITION_UPDATE_INTERVAL = 3;

  Future<Position> getCurrentPosition(LocationAccuracy accuracy) async {
    return await geoService.getCurrentPosition(accuracy);
  }

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
    final position = await getCurrentPosition(config.value!.accuracy);
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
    // ######## Update MyBoat Status ########
    final latestMyBoat = await getLatestMyBoat();
    myBoat.value = latestMyBoat;

    // ######## Send Message ########
    final message = Message.fromBoat(latestMyBoat);
    final messageService = MessageService();
    // messageService.sendMessage(message);

    // ######## Evaluate Collision Risk ########
    final evaluator = CollisionRiskEvaluatorService();
    final riskLevel = evaluator.evaluateRisk(
      latestMyBoat,
      otherBoats.value,
    );
    final safetyLevel_ = getSafetyLevelFrom(riskLevel);
    safetyLevel.value = safetyLevel_;

    // ######## Alert ########
    // useEffectにて実装
  }

  startNavigation(NavConfig config_) async {
    // モードを変更
    mode.value = NavMode.navigator;
    // 初期化
    safetyLevel.value = SafetyLevel.safe;
    final messageService = MessageService();
    await messageService.clearMessage(config_.boatId);
    // 設定を保存
    config.value = config_;
    // ナビゲーションを開始
    await navigate();
    watchTimer.value = Timer.periodic(
        Duration(seconds: POSITION_UPDATE_INTERVAL), (timer) async {
      await navigate();
    });
  }

  stopNavigation() async {
    // モードを変更
    mode.value = NavMode.observer;
    // 終了処理
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
    // ######## Alert ########
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
    config: config.value,
    mode: mode.value,
    safetyLevel: safetyLevel.value,
    myBoat: myBoat.value,
    otherBoats: otherBoats.value,
    preProcessTime: preProcessTime.value,
    postProcessTime: postProcessTime.value,
    getCurrentPosition: getCurrentPosition,
    startNavigation: startNavigation,
    stopNavigation: stopNavigation,
  );
}

class UseNavigator {
  final NavConfig? config;
  final NavMode mode;
  final SafetyLevel safetyLevel;
  final Boat? myBoat;
  final List<Boat> otherBoats;
  final DateTime preProcessTime;
  final DateTime postProcessTime;
  final Future<Position> Function(LocationAccuracy accuracy) getCurrentPosition;
  final Future<void> Function(NavConfig config) startNavigation;
  final Future<void> Function() stopNavigation;

  UseNavigator({
    required this.config,
    required this.mode,
    required this.safetyLevel,
    required this.myBoat,
    required this.otherBoats,
    required this.preProcessTime,
    required this.postProcessTime,
    required this.getCurrentPosition,
    required this.startNavigation,
    required this.stopNavigation,
  });
}
