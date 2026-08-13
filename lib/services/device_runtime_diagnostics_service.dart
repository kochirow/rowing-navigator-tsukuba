import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';

/// GPS途絶時の「端末側」を切り分ける読取り専用スナップショット。
///
/// 取得に失敗してもGPSの再購読や危険判定は止めない。個別項目を
/// best-effortで読み、欠けた項目だけ省略する。
class DeviceRuntimeDiagnosticsService {
  static const _channel = MethodChannel(
    'jp.kosei.rowingnavigator.tsukuba/device_diagnostics',
  );

  final Battery _battery;

  DeviceRuntimeDiagnosticsService({Battery? battery})
      : _battery = battery ?? Battery();

  Future<Map<String, Object?>> snapshot() async {
    final result = <String, Object?>{
      'platform': defaultTargetPlatform.name,
      'lifecycle': WidgetsBinding.instance.lifecycleState?.name ?? 'unknown',
    };

    try {
      result['locationServiceEnabled'] =
          await Geolocator.isLocationServiceEnabled();
    } catch (_) {}
    try {
      result['locationPermission'] = (await Geolocator.checkPermission()).name;
    } catch (_) {}
    try {
      result['locationAccuracyAuthorization'] =
          (await Geolocator.getLocationAccuracy()).name;
    } catch (_) {}
    try {
      result['batterySaveMode'] = await _battery.isInBatterySaveMode;
    } catch (_) {}

    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android)) {
      try {
        final native = await _channel.invokeMapMethod<String, Object?>(
          'snapshot',
        );
        if (native != null) result.addAll(native);
      } catch (_) {}
    }
    return result;
  }
}
