import 'package:shared_preferences/shared_preferences.dart';

import '../config/warning_audio_config.dart';

/// アプリ内の警告音量(端末内設定)。
///
/// 読み書きに失敗しても既定(100%)へ倒し、航行や警告を止めない。
/// AccountDataDeletionService の SharedPreferences 全消去対象。
class WarningAudioVolumeSettingsService {
  static const _volumeKey = 'warning_audio_app_volume_v1';

  Future<double> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return normalizeWarningAudioAppVolume(prefs.getDouble(_volumeKey));
    } catch (_) {
      return warningAudioAppVolumeDefault;
    }
  }

  Future<void> save(double volume) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(
        _volumeKey,
        normalizeWarningAudioAppVolume(volume),
      );
    } catch (_) {
      // 保存できなくても今回の音量は変わっている。次回の起動で
      // 100% へ戻るだけなので、航行を止めてまで知らせる価値はない。
    }
  }
}
