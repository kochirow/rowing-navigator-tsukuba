import 'package:shared_preferences/shared_preferences.dart';

import '../config/coach_config.dart';
import 'observer_background_alert_policy.dart';

/// 背面の通知の種類ごとのオン・オフ(R3)。端末ごとに保存する。
/// 読めないときは既定([observerBackgroundAlertDefaultEnabled])を使う。
class ObserverBackgroundAlertSettingsService {
  static const _key = 'observer_background_alert_kinds_v1';

  static Set<ObserverBackgroundAlertKind> get defaults =>
      observerBackgroundAlertDefaultEnabled
          ? {...ObserverBackgroundAlertKind.values}
          : <ObserverBackgroundAlertKind>{};

  Future<Set<ObserverBackgroundAlertKind>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final names = prefs.getStringList(_key);
      if (names == null) return defaults;
      return {
        for (final name in names)
          if (ObserverBackgroundAlertKind.fromName(name) case final kind?) kind,
      };
    } catch (_) {
      return defaults;
    }
  }

  Future<void> save(Set<ObserverBackgroundAlertKind> kinds) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_key, [for (final kind in kinds) kind.name]);
    } catch (_) {/* 設定の失敗で監視を止めない */}
  }
}
