import 'dart:async';

import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../config/navigator_config.dart';
import '../types/nav_mode.dart';

/// 常時点灯は航行中だけ必要かを決める純粋な判断。
///
/// 漕手は航行中に端末を操作できない一方、監視者は陸上で操作できるため、
/// observer / isWatching は常時点灯の条件に含めない。
bool shouldKeepScreenAwake(NavMode mode) => mode == NavMode.navigator;

abstract interface class ScreenWakelockPlatform {
  Future<bool> get enabled;

  Future<void> enable();

  Future<void> disable();
}

class _WakelockPlusPlatform implements ScreenWakelockPlatform {
  const _WakelockPlusPlatform();

  @override
  Future<bool> get enabled => WakelockPlus.enabled;

  @override
  Future<void> enable() => WakelockPlus.enable();

  @override
  Future<void> disable() => WakelockPlus.disable();
}

typedef ScreenWakelockDiagnostic = void Function(
  String type,
  Map<String, dynamic> details,
);

/// Wakelock の実状態を読み、必要な時だけ切り替える単一の窓口。
///
/// テストでは [platform] を差し替えられる。プラットフォーム操作に失敗しても
/// 航行そのものは止めず、診断だけを残す。
class ScreenWakelockController {
  ScreenWakelockController({
    required this.platform,
    required this.onDiagnostic,
  });

  final ScreenWakelockPlatform platform;
  final ScreenWakelockDiagnostic onDiagnostic;

  Future<void> apply({
    required bool desired,
    required String reason,
  }) async {
    bool? actual;
    try {
      actual = await platform.enabled;
      if (actual != desired) {
        if (desired) {
          await platform.enable();
        } else {
          await platform.disable();
        }
      }
      actual = await platform.enabled;
    } catch (error) {
      debugPrint('Wakelock state update failed: $error');
    }
    onDiagnostic('wakelock_state_changed', {
      'desired': desired,
      'actual': actual,
      'reason': reason,
    });
  }
}

/// 常時点灯の唯一の管理者。他のどこからも [WakelockPlus] を呼ばないこと。
///
/// 航行中だけ画面を保ち、OS復帰時と定期実行時に実状態を再確認する。
void useScreenWakelock({
  required bool shouldKeepAwake,
  required ScreenWakelockDiagnostic onDiagnostic,
  ScreenWakelockPlatform? platform,
}) {
  final diagnosticRef = useRef<ScreenWakelockDiagnostic>(onDiagnostic);
  diagnosticRef.value = onDiagnostic;
  final controller = useMemoized(
    () => ScreenWakelockController(
      platform: platform ?? const _WakelockPlusPlatform(),
      onDiagnostic: (type, details) => diagnosticRef.value(type, details),
    ),
    [platform],
  );
  final desiredRef = useRef(shouldKeepAwake);
  desiredRef.value = shouldKeepAwake;

  useEffect(() {
    unawaited(controller.apply(
      desired: shouldKeepAwake,
      reason: 'state_changed',
    ));
    final reassertTimer = Timer.periodic(screenWakelockReassertInterval, (_) {
      unawaited(controller.apply(
        desired: desiredRef.value,
        reason: 'periodic_reassert',
      ));
    });
    return reassertTimer.cancel;
  }, [controller, shouldKeepAwake]);

  useOnAppLifecycleStateChange((_, current) {
    if (current != AppLifecycleState.resumed) return;
    unawaited(controller.apply(
      desired: desiredRef.value,
      reason: 'lifecycle_resumed',
    ));
  });

  useEffect(() {
    return () {
      unawaited(controller.apply(
        desired: false,
        reason: 'dispose',
      ));
    };
  }, [controller]);
}
