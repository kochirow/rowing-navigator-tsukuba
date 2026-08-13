import 'package:shared_preferences/shared_preferences.dart';

/// 地図の見え方に関する端末内設定。
///
/// 表示だけの設定なので、読み書きに失敗しても既定値へ倒し、航行や警告を
/// 止めない。AccountDataDeletionService の SharedPreferences 全消去対象。
class MapDisplaySettingsService {
  static const _highContrastKey = 'map_high_contrast_v1';
  static const _developerSafetyShapeOverlayKey =
      'map_developer_safety_shape_overlay_v1';
  static const _showChannelLanesKey = 'map_show_channel_lanes_v1';

  Future<bool> loadHighContrast() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_highContrastKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> saveHighContrast(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_highContrastKey, enabled);
    } catch (_) {
      // 保存できなくても今回の表示は切り替わっている。次回の起動で
      // 既定へ戻るだけなので、航行を止めてまで知らせる価値はない。
    }
  }

  /// 航路(往路・復路)の帯を地図へ描くか。
  ///
  /// **既定はON。** 右側通行の片側1レーンで運用しているため、どちらの帯に
  /// いるかは常に必要な情報である。読み書きに失敗してもONへ倒す
  /// (表示が消えるより、余分に出るほうが安全側)。
  Future<bool> loadShowChannelLanes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_showChannelLanesKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<void> saveShowChannelLanes(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_showChannelLanesKey, enabled);
    } catch (_) {
      // 保存できなくても今回の表示は切り替わっている。次回の起動で
      // 既定へ戻るだけなので、航行を止めてまで知らせる価値はない。
    }
  }

  /// 開発者が判定形状を確認するための表示専用トグル。
  ///
  /// 航行・衝突判定の入力には使わない。保存に失敗しても既定OFFへ戻るだけで、
  /// 実際の警告経路は変化させない。
  Future<bool> loadDeveloperSafetyShapeOverlay() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_developerSafetyShapeOverlayKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> saveDeveloperSafetyShapeOverlay(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_developerSafetyShapeOverlayKey, enabled);
    } catch (_) {
      // 開発用の表示設定だけなので、失敗を航行画面へ波及させない。
    }
  }
}
