import 'package:shared_preferences/shared_preferences.dart';

import '../config/coach_config.dart';

/// 監視端末の「警告をバイブで知らせる」の端末内設定。
///
/// 読み書きに失敗しても既定(ON)へ倒し、監視表示を止めない。
/// AccountDataDeletionService の SharedPreferences 全消去対象。
class ObserverWarningSettingsService {
  static const _vibrationKey = 'observer_warning_vibration_v1';

  Future<bool> loadVibrationEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_vibrationKey) ??
          observerWarningVibrationDefaultEnabled;
    } catch (_) {
      return observerWarningVibrationDefaultEnabled;
    }
  }

  Future<void> saveVibrationEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_vibrationKey, enabled);
    } catch (_) {
      // 今回の監視では切り替わっている。次回の起動で既定へ戻るだけ。
    }
  }
}
