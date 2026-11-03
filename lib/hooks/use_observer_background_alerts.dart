import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../config/coach_config.dart';
import '../models/message_model.dart';
import '../services/observer_background_alert_policy.dart';
import '../services/observer_background_alert_settings_service.dart';
import '../services/observer_notification_service.dart';
import '../services/preset_obstacle_service.dart';
import '../utils/winding_algorithm.dart';

class UseObserverBackgroundAlerts {
  /// いまオンの種類。艇一覧の上の切り替えに使う。
  final ValueNotifier<Set<ObserverBackgroundAlertKind>> enabledKinds;
  final void Function(ObserverBackgroundAlertKind kind, bool on) setEnabled;

  /// 通知の許可。まだ聞いていなければ null。
  final ValueNotifier<bool?> permissionGranted;

  const UseObserverBackgroundAlerts({
    required this.enabledKinds,
    required this.setEnabled,
    required this.permissionGranted,
  });
}

/// 監視端末が背面にある間に、漕手の警告・更新途絶・長時間停止を通知で出す(R3)。
///
/// **画面の描画に頼らない。** 受信は [messages] を直接購読し、途絶・停止は
/// タイマーで判定する。背面では Flutter が描画しないので、hook の effect に
/// 載せると背面で何も起きない。前面にあるかは、判定のたびに OS の状態を読む。
///
/// 通知したもの(許可が無く出せなかったものも)は [onRecord] で監視ログへ残す。
UseObserverBackgroundAlerts useObserverBackgroundAlerts({
  required bool enabled,
  required ValueListenable<List<Message>> messages,
  required void Function(String type, Map<String, dynamic> details) onRecord,
  ObserverNotificationService? service,
}) {
  final notifications =
      useMemoized(() => service ?? ObserverNotificationService());
  final settings = useMemoized(ObserverBackgroundAlertSettingsService.new);
  final enabledKinds = useState<Set<ObserverBackgroundAlertKind>>(
      ObserverBackgroundAlertSettingsService.defaults);
  final permissionGranted = useState<bool?>(null);
  final changedByUser = useRef(false);
  final kindsRef = useRef(enabledKinds.value);
  kindsRef.value = enabledKinds.value;
  final onRecordRef = useRef(onRecord);
  onRecordRef.value = onRecord;

  useEffect(() {
    var disposed = false;
    unawaited(settings.load().then((kinds) {
      if (disposed || changedByUser.value) return;
      enabledKinds.value = kinds;
      kindsRef.value = kinds;
    }));
    return () => disposed = true;
  }, const []);

  useEffect(() {
    if (!enabled) return null;
    var disposed = false;
    var quietAreas = const <List<LatLng>>[];
    final policy = ObserverBackgroundAlertPolicy(
      isQuietPlace: (lat, lng) {
        final point = LatLng(lat, lng);
        return quietAreas.any((area) => isPointInPolygon(point, area));
      },
    );
    unawaited(() async {
      try {
        final preset = PresetObstacleService();
        final mooring = await preset.loadMooringAreas();
        final harbor = await preset.loadHarborAreas();
        quietAreas = [
          for (final area in mooring) area.points,
          for (final area in harbor) area.points,
        ];
      } catch (_) {/* 区域が読めなくても通知は続ける */}
    }());
    if (permissionGranted.value == null) {
      unawaited(notifications.requestPermission().then((granted) {
        if (!disposed) permissionGranted.value = granted;
      }));
    }

    void evaluate() {
      if (disposed) return;
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      final foreground =
          lifecycle == null || lifecycle == AppLifecycleState.resumed;
      final List<ObserverBackgroundAlert> alerts;
      try {
        alerts = policy.update(
          messages: messages.value,
          now: DateTime.now(),
          foreground: foreground,
          enabled: kindsRef.value,
        );
      } catch (_) {
        return; // 判定の失敗で監視を止めない
      }
      for (final alert in alerts) {
        unawaited(notifications
            .show(boatId: alert.boatId, body: alert.body)
            .then((delivered) {
          onRecordRef.value('observer_background_notified',
              alert.toDiagnosticDetails(delivered: delivered));
        }));
      }
    }

    messages.addListener(evaluate);
    final timer = Timer.periodic(
      const Duration(seconds: observerBackgroundAlertTickSec),
      (_) => evaluate(),
    );
    return () {
      disposed = true;
      messages.removeListener(evaluate);
      timer.cancel();
    };
  }, [enabled, messages]);

  void setEnabled(ObserverBackgroundAlertKind kind, bool on) {
    changedByUser.value = true;
    final next = {...enabledKinds.value};
    if (on) {
      next.add(kind);
    } else {
      next.remove(kind);
    }
    enabledKinds.value = next;
    kindsRef.value = next;
    unawaited(settings.save(next));
  }

  return UseObserverBackgroundAlerts(
    enabledKinds: enabledKinds,
    setEnabled: setEnabled,
    permissionGranted: permissionGranted,
  );
}
