import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map_math/flutter_geo_math.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../hooks/useAlert.dart';
import '../models/boat_model.dart';
import '../models/nav_config_model.dart';
import '../models/static_obstacle_model.dart';
import '../services/collision_risk_evaluator_service.dart';
import '../services/env_service.dart';
import '../services/geo_service.dart';
import '../services/message_service.dart';
import '../types/alert_type.dart';
import '../types/collision_risk_level.dart';
import '../types/nav_mode.dart';
import '../types/safety_level.dart';
import '../utils/heading.dart';

UseNavigator useNavigator() {
  // Navigator
  final config = useState<NavConfig?>(null);
  final mode = useState<NavMode>(NavMode.observer);
  final safetyLevel = useState<SafetyLevel>(SafetyLevel.safe);
  final myBoat = useState<Boat?>(null);
  final otherBoats = useState<List<Boat>>([]);
  final obstacles = useState<List<StaticObstacle>>([]);
  final heading = useState<double?>(null);
  final preRawPos = useState<Position?>(null);
  // Streams
  final headingStreamSubscription = useState<StreamSubscription?>(null);
  final dynamicObsStreamSubscription = useState<StreamSubscription?>(null);
  final staticObsStreamSubscription = useState<StreamSubscription?>(null);
  final watchTimer = useState<Timer?>(null);
  // Time
  final preProcessTime = useState<DateTime>(DateTime.now());
  final postProcessTime = useState<DateTime>(DateTime.now());
  // Hooks
  final alert = useAlert();
  // Services
  final geoService = GeoService();
  final messageService = MessageService();
  final evaluatorService = CollisionRiskEvaluatorService();

  // Constants
  final POSITION_UPDATE_INTERVAL = 3;

  Future<Position> getCurrentPosition(LocationAccuracy accuracy) async {
    return await geoService.getCurrentPosition(accuracy);
  }

  Position getDestinationPosition(
      Position pos, double distance, double heading) {
    LatLng currentLatLng = LatLng(pos.latitude, pos.longitude);
    final destinationLatLng = FlutterMapMath().destinationPoint(
      currentLatLng.latitude,
      currentLatLng.longitude,
      distance,
      heading,
    );
    return Position(
      latitude: destinationLatLng.latitude,
      longitude: destinationLatLng.longitude,
      timestamp: pos.timestamp,
      accuracy: pos.accuracy,
      altitude: pos.altitude,
      heading: pos.heading,
      speed: pos.speed,
      speedAccuracy: pos.speedAccuracy,
      altitudeAccuracy: pos.altitudeAccuracy,
      headingAccuracy: pos.headingAccuracy,
    );
  }

  double getDistanceBetween(Position pos1, Position pos2) {
    final distance = Geolocator.distanceBetween(
      pos1.latitude,
      pos1.longitude,
      pos2.latitude,
      pos2.longitude,
    );
    return distance;
  }

  watchHeading() {
    headingStreamSubscription.value = FlutterCompass.events?.listen((snapshot) {
      heading.value = snapshot.heading;
    });
  }

  watchEnv() {
    final envService = EnvService();
    dynamicObsStreamSubscription.value =
        envService.getDynamicObstaclesStream().listen((obstacles) {
      final List<Boat> boats = obstacles['boats'];
      otherBoats.value = boats
          .where((boat) => config.value != null
              ? (boat.boatId != config.value!.boatId)
              : true)
          .toList();
    });
    staticObsStreamSubscription.value =
        envService.getStaticObstaclesStream().listen((obstacles_) {
      final List<StaticObstacle> staticObs = obstacles_['obstacles'] ?? [];
      obstacles.value = staticObs;
    });
  }

  getLatestMyBoat() async {
    preProcessTime.value = DateTime.now(); // Pre-Process Time
    final rawPos = await getCurrentPosition(config.value!.accuracy);
    postProcessTime.value = DateTime.now(); // Post-Process Time
    double heading_; // 艇情報として使用される方位角
    if (heading.value == null) {
      // Compassで方位角を取れていない場合は前回の位置情報から算出
      if (preRawPos.value != null) {
        heading_ = getHeading(
          LatLng(preRawPos.value!.latitude, preRawPos.value!.longitude),
          LatLng(rawPos.latitude, rawPos.longitude),
        ); // 艇の中心にいると仮定しているため少し誤差がある
      } else {
        heading_ = 0.0;
      }
    } else {
      // Compassで方位角を取れている場合はその値を使用
      heading_ = heading.value!;
    }
    double speed_; // 艇情報として使用される速度
    if (rawPos.speed < 0) {
      // 直前の位置情報がある場合は直前の位置情報から算出
      speed_ = preRawPos.value == null
          ? 0.0
          : getDistanceBetween(preRawPos.value!, rawPos);
    } else {
      // 速度情報が正常な場合はその値を使用
      speed_ = rawPos.speed;
    }
    // print("speed = $speed_");
    final offset =
        Boat.getSeatOffset(config.value!.boatType, config.value!.seatPos);
    final position = getDestinationPosition(
      rawPos,
      offset,
      heading_,
    );
    preRawPos.value = rawPos; // 地理座標から方位角を算出する場合に使用するため保存
    return Boat(
      boatId: config.value!.boatId, // 自艇のID
      boatType: config.value!.boatType, // 自艇のtype
      lat: position.latitude,
      lng: position.longitude,
      heading: heading_,
      speed: speed_,
      timestamp: position.timestamp,
    );
  }

  getSafetyLevelFrom(CollisionRiskLevel riskLevel) {
    switch (riskLevel) {
      case CollisionRiskLevel.lv0:
        return SafetyLevel.safe;
      case CollisionRiskLevel.lv1:
        return SafetyLevel.caution;
      case CollisionRiskLevel.lv2:
        return SafetyLevel.warning;
      case CollisionRiskLevel.lv3:
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
    final message = latestMyBoat.toMessage();
    // messageService.sendMessage(message);

    // ######## Evaluate Collision Risk ########
    final riskLevel = evaluatorService.evaluateFutureRisk(
      latestMyBoat,
      otherBoats.value,
      obstacles.value,
    );
    // print("Risk Level: $riskLevel");
    final safetyLevel_ = getSafetyLevelFrom(riskLevel);
    safetyLevel.value = safetyLevel_;

    // ######## Alert ########
    // useEffectにて実装
  }

  startNavigation(NavConfig config_) async {
    // モードを変更
    mode.value = NavMode.navigator;
    WakelockPlus.enable(); // spell-checker:disable-line
    // 初期化
    safetyLevel.value = SafetyLevel.safe;
    final messageService = MessageService();
    await messageService.clearMessage(config_.boatId);
    // 設定を保存
    config.value = config_;
    print(
        "CONFIG - BoatType: ${config.value!.boatType.name}, SeatPos: ${config.value!.seatPos.label}");
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
    WakelockPlus.disable(); // spell-checker:disable-line
    // 終了処理
    watchTimer.value?.cancel();
    final messageService = MessageService();
    await messageService.clearMessage(config.value!.boatId);
    myBoat.value = null;
    config.value = null;
    safetyLevel.value = SafetyLevel.safe;
  }

  useEffect(() {
    watchHeading();
    watchEnv();
    return () {
      headingStreamSubscription.value?.cancel();
      dynamicObsStreamSubscription.value?.cancel();
      staticObsStreamSubscription.value?.cancel();
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
    config: config,
    mode: mode,
    safetyLevel: safetyLevel,
    myBoat: myBoat,
    otherBoats: otherBoats,
    obstacles: obstacles,
    preProcessTime: preProcessTime,
    postProcessTime: postProcessTime,
    getCurrentPosition: getCurrentPosition,
    startNavigation: startNavigation,
    stopNavigation: stopNavigation,
  );
}

class UseNavigator {
  final ValueNotifier<NavConfig?> config;
  final ValueNotifier<NavMode> mode;
  final ValueNotifier<SafetyLevel> safetyLevel;
  final ValueNotifier<Boat?> myBoat;
  final ValueNotifier<List<Boat>> otherBoats;
  final ValueNotifier<List<StaticObstacle>> obstacles;
  final ValueNotifier<DateTime> preProcessTime;
  final ValueNotifier<DateTime> postProcessTime;
  final Future<Position> Function(LocationAccuracy accuracy) getCurrentPosition;
  final Future<void> Function(NavConfig config) startNavigation;
  final Future<void> Function() stopNavigation;

  UseNavigator({
    required this.config,
    required this.mode,
    required this.safetyLevel,
    required this.myBoat,
    required this.otherBoats,
    required this.obstacles,
    required this.preProcessTime,
    required this.postProcessTime,
    required this.getCurrentPosition,
    required this.startNavigation,
    required this.stopNavigation,
  });
}
