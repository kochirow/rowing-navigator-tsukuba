import 'package:firebase_core/firebase_core.dart';

import '../models/boat_model.dart';
import '../models/session_model.dart';
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

/// 他艇の警告の記録に添える、相手の速度と方位を信頼したか(R8-R1)。
///
/// 方位の信頼は評価と同じ規則([ShipDomainService.headingIsReliable])で決める。
/// 相手が一覧に無い(受信が切れた)ときは null を返し、値を作らない。
({double? speedMps, bool? headingReliable}) otherBoatTargetDiagnostics(
  Boat? boat,
) {
  if (boat == null) return (speedMps: null, headingReliable: null);
  final speed = boat.speed;
  return (
    speedMps: speed.isFinite ? speed : null,
    headingReliable: ShipDomainService.headingIsReliable(boat),
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
