import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../config/coach_config.dart';
import '../models/message_model.dart';
import '../services/observer_warning_notifier.dart';
import '../services/observer_warning_settings_service.dart';
import '../utils/tactile_feedback.dart';

/// 監視端末で、航行中の艇の漕手に鳴った警告を知らせる。
///
/// - 漕手に音が鳴った(band 1・2)艇を、地図の艇印と艇一覧で目立たせる([active])。
/// - 画面が前面にある間だけ、バイブで1回知らせる(2026-10-30 利用者決定)。
/// - 通知したものは [notifications] に積み、監視ログへ `observer_warning_notified`
///   として残す(過剰でないかを後から確かめるため)。
///
/// 受信した他艇の警告状態は、監視端末での通知・表示にだけ使う(不変条件12)。
/// 航行中の端末では [enabled] が false なので何もしない。
class UseObserverWarningAlerts {
  final ValueNotifier<Map<String, ObserverBoatWarning>> active;
  final ValueNotifier<List<ObserverWarningVibration>> notifications;
  final ValueNotifier<bool> vibrationEnabled;
  final void Function(bool enabled) setVibrationEnabled;

  const UseObserverWarningAlerts({
    required this.active,
    required this.notifications,
    required this.vibrationEnabled,
    required this.setVibrationEnabled,
  });

  /// 地図の艇印に添える種類の短い名前。音が鳴っていなければ null。
  String? mapLabelFor(String boatId) => active.value[boatId]?.categoryLabel;
}

UseObserverWarningAlerts useObserverWarningAlerts({
  required bool enabled,
  required List<Message> messages,
}) {
  final settings = useMemoized(ObserverWarningSettingsService.new);
  final notifier = useMemoized(ObserverWarningNotifier.new);
  final active = useState<Map<String, ObserverBoatWarning>>(const {});
  final notifications = useState<List<ObserverWarningVibration>>(const []);
  final vibrationEnabled = useState(observerWarningVibrationDefaultEnabled);
  // 保存値の読込より先に利用者が切り替えたら、その選択を読込で上書きしない。
  final vibrationChangedByUser = useRef(false);
  final latestMessages = useRef(messages);
  latestMessages.value = messages;
  final lifecycle = useAppLifecycleState();
  final foreground = (lifecycle ??
          WidgetsBinding.instance.lifecycleState ??
          AppLifecycleState.resumed) ==
      AppLifecycleState.resumed;
  final latestForeground = useRef(foreground);
  latestForeground.value = foreground;

  useEffect(() {
    var disposed = false;
    unawaited(settings.loadVibrationEnabled().then((value) {
      if (!disposed && !vibrationChangedByUser.value) {
        vibrationEnabled.value = value;
      }
    }));
    return () => disposed = true;
  }, const []);

  void evaluate() {
    final update = notifier.update(
      inputs: latestMessages.value.map((message) => ObserverWarningInput(
            boatId: message.boatId,
            presentationState: message.presentationState,
            observedAt: message.serverUpdatedAt ?? message.timestamp,
          )),
      now: DateTime.now(),
      deliver: latestForeground.value,
    );
    if (!_sameWarnings(active.value, update.active)) {
      active.value = update.active;
    }
    final vibration = update.vibration;
    if (vibration == null) return;
    if (vibrationEnabled.value) {
      TactileFeedback.observerWarning(
        continuous: vibration.band == ObserverWarningBand.continuous,
        secondDelay: observerWarningSecondVibrationDelay,
      );
    }
    // 記録は直近だけ持てば足りる(監視ログ側が新しいものだけを書く)。
    final next = [...notifications.value, vibration];
    notifications.value = List.unmodifiable(
        next.length > 20 ? next.sublist(next.length - 20) : next);
  }

  // 受信のたびと、受信が止まっても古くなった警告を落とせるよう毎秒評価する。
  useEffect(() {
    if (!enabled) {
      notifier.reset();
      if (active.value.isNotEmpty) active.value = const {};
      return null;
    }
    evaluate();
    final timer = Timer.periodic(const Duration(seconds: 1), (_) => evaluate());
    return timer.cancel;
  }, [enabled]);

  useEffect(() {
    if (enabled) evaluate();
    return null;
  }, [messages, foreground]);

  return UseObserverWarningAlerts(
    active: active,
    notifications: notifications,
    vibrationEnabled: vibrationEnabled,
    setVibrationEnabled: (value) {
      vibrationChangedByUser.value = true;
      vibrationEnabled.value = value;
      unawaited(settings.saveVibrationEnabled(value));
    },
  );
}

bool _sameWarnings(
  Map<String, ObserverBoatWarning> a,
  Map<String, ObserverBoatWarning> b,
) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
