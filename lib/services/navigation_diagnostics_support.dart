import 'package:firebase_core/firebase_core.dart';

import '../config/location_activity_config.dart';
import '../models/boat_model.dart';
import '../models/session_model.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'same_direction_detector.dart';
import 'ship_domain_service.dart';

/// 航行中の診断ログ(events.jsonl・alerts.jsonl)に残す値を作る補助。
///
/// どれも記録専用で、衝突評価・提示・位置共有には使わない。
/// `use_navigator.dart` を太らせないよう、ここへ切り出している。

/// 位置共有の失敗を、原因を切り分けられる形で残す。
Map<String, Object?> positionSharingErrorDetails(Object error) {
  if (error is FirebaseException) {
    final message = error.message?.replaceAll(RegExp(r'\s+'), ' ').trim();
    return {
      'errorType': 'FirebaseException',
      'errorCode': error.code,
      'plugin': error.plugin,
      if (message != null && message.isNotEmpty)
        'message': message.length <= 240 ? message : message.substring(0, 240),
      if (error.code == 'permission-denied')
        'likelyCause':
            'rtdb_rules_payload_membership_auth_app_check_or_deployed_rules',
    };
  }
  return {'errorType': error.runtimeType.toString()};
}

/// 原因分類に使う errorCode。Firebase 以外は null。
String? sharingErrorCode(Object error) =>
    error is FirebaseException ? error.code : null;

/// 他艇の警告の記録に添える相手の動き(R8-R1)。
typedef OtherBoatTargetDiagnostics = ({
  double? speedMps,
  bool? headingReliable,
  double? headingDeg,
  double? alongMeters,
  double? lateralMeters,
});

const OtherBoatTargetDiagnostics _noTargetDiagnostics = (
  speedMps: null,
  headingReliable: null,
  headingDeg: null,
  alongMeters: null,
  lateralMeters: null,
);

/// 他艇の警告の記録に添える、相手の速度・向き・方位を信頼したか(R8-R1)と、
/// 自艇の向きを基準にした相手の位置(前後・横。2026-11-09 追加)。
///
/// 方位の信頼は評価と同じ規則([ShipDomainService.headingIsReliable])で決める。
/// 相手が一覧に無い(受信が切れた)ときは null を返し、値を作らない。
/// 自艇が無ければ前後・横は null。
OtherBoatTargetDiagnostics otherBoatTargetDiagnostics(
  Boat? boat, {
  Boat? own,
}) {
  if (boat == null) return _noTargetDiagnostics;
  final speed = boat.speed;
  final geometry = own == null
      ? null
      : SameDirectionDetector.relativeGeometry(
          ownPosition: LatLng(own.lat, own.lng),
          ownHeading: own.heading,
          otherPosition: LatLng(boat.lat, boat.lng),
        );
  return (
    speedMps: speed.isFinite ? speed : null,
    headingReliable: ShipDomainService.headingIsReliable(boat),
    headingDeg: boat.heading.isFinite ? boat.heading : null,
    alongMeters: geometry?.alongMeters,
    lateralMeters: geometry?.lateralMeters,
  );
}

/// 途切れた記録が見つかったときの、最後の様子(R8-R2)。
///
/// 途切れる直前のライフサイクル・電池・温度・メモリ警告を、記録に残っている
/// 診断イベントから拾う。どれも見つからなければ null のまま残す
/// (無いことを「問題なし」と読ませない)。
Map<String, Object?> sessionRecoveryContext(Session session) {
  String? lastLifecycle;
  DateTime? lastLifecycleAt;
  int? lastBatteryPercent;
  String? lastThermalState;
  bool? lastLowPowerMode;
  var memoryPressureCount = 0;
  DateTime? lastMemoryPressureAt;
  for (final event in session.diagnosticEvents) {
    final details = event.details;
    switch (event.type) {
      case 'app_lifecycle_changed':
        final to = details['to'];
        if (to is String) {
          lastLifecycle = to;
          lastLifecycleAt = event.t;
        }
      case 'diagnostic_heartbeat':
        final lifecycle = details['lifecycle'];
        if (lifecycle is String &&
            (lastLifecycleAt == null || !event.t.isBefore(lastLifecycleAt))) {
          lastLifecycle = lifecycle;
          lastLifecycleAt = event.t;
        }
      case 'battery_level_changed':
        final level = details['levelPercent'];
        if (level is num) lastBatteryPercent = level.toInt();
      case 'gps_environment_snapshot':
        final thermal = details['thermalState'];
        if (thermal is String) lastThermalState = thermal;
        final lowPower = details['lowPowerModeEnabled'];
        if (lowPower is bool) lastLowPowerMode = lowPower;
      case 'memory_pressure':
        memoryPressureCount++;
        lastMemoryPressureAt = event.t;
    }
  }
  return {
    'lastLifecycle': lastLifecycle,
    'lastLifecycleAt': lastLifecycleAt?.toUtc().toIso8601String(),
    'lastBatteryPercent': lastBatteryPercent,
    'lastThermalState': lastThermalState,
    'lastLowPowerModeEnabled': lastLowPowerMode,
    'memoryPressureCount': memoryPressureCount,
    'lastMemoryPressureAt': lastMemoryPressureAt?.toUtc().toIso8601String(),
  };
}

/// 位置取得の用途指定の記録(R7-R2)。
///
/// 指定した用途、実際に効いた種類、geolocator_apple の版を残す。効いた種類は
/// 端末の iOS の版と、アプリを作った SDK(Info.plist の `DTSDKName`)で決まる。
/// どちらかが読めなければ `locationActivityEffective` は null のまま残す。
Map<String, Object?> locationActivityDiagnostics({
  required NavigationLocationActivity requested,
  Map<String, Object?> deviceSnapshot = const {},
}) {
  final isIos = deviceSnapshot['platform'] == 'iOS' ||
      deviceSnapshot['systemName'] == 'iOS' ||
      deviceSnapshot['systemName'] == 'iPadOS';
  final systemVersion = deviceSnapshot['systemVersion'];
  final sdkName = deviceSnapshot['buildSdkName'];
  return {
    'locationActivityRequested': requested.name,
    if (deviceSnapshot.isNotEmpty)
      'locationActivityEffective': effectiveLocationActivityName(
        requested: requested,
        isIos: isIos,
        iosMajorVersion:
            leadingMajorVersion(systemVersion is String ? systemVersion : null),
        sdkMajorVersion:
            leadingMajorVersion(sdkName is String ? sdkName : null),
      ),
    'geolocatorAppleVersion': geolocatorAppleVersion,
  };
}
