import 'package:shared_preferences/shared_preferences.dart';

/// 初回の案内を表示済みかを端末内に覚える。表示専用で、安全経路とは無関係。
///
/// 一度表示したら、最後まで見てもスキップしても再表示しない
/// (Apple HIG Onboarding: スキップされた案内は次回以降出さず、ヘルプから開けるようにする)。
/// 使い方のトップからは何度でも開ける。
///
/// 読み書きに失敗したときは「表示しない」側に倒す。地図はそのまま使え、
/// 失敗のたびに案内が出るほうが邪魔になるため。
class FirstRunGuideStore {
  const FirstRunGuideStore();

  static const seenKey = 'first_run_guide_seen_v1';

  /// 既存の利用者を見分けるための、航行設定の保存キー
  /// (`NavigationDefaultsService` の名前)。これがある端末は一度は航行しており、
  /// 案内を出さない。
  static const existingUserKey = 'navigation_display_name_v1';

  /// 案内を出すべきなら true。既存の利用者はここで表示済みにする。
  Future<bool> shouldShow() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(seenKey) ?? false) return false;
      if (prefs.containsKey(existingUserKey)) {
        await prefs.setBool(seenKey, true);
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 表示済みにする。失敗しても例外を出さない。
  Future<void> markSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(seenKey, true);
    } catch (_) {
      // 次回もう一度出るだけで、機能には影響しない。
    }
  }
}
