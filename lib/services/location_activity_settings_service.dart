import 'package:shared_preferences/shared_preferences.dart';

import '../config/location_activity_config.dart';

/// 航行中の位置取得の用途指定を、端末ごとに戻すための設定(R7-R4)。
///
/// 既定は [defaultNavigationLocationActivity]。水上で悪化に気づいたとき、
/// 次のビルドを待たずにその端末だけ `fitness` へ戻せるようにする。
/// 読み書きに失敗しても航行は止めず、既定を使う。
class LocationActivitySettingsService {
  static const _key = 'navigation_location_activity_v1';

  Future<NavigationLocationActivity> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return NavigationLocationActivity.fromName(prefs.getString(_key)) ??
          defaultNavigationLocationActivity;
    } catch (_) {
      return defaultNavigationLocationActivity;
    }
  }

  Future<void> save(NavigationLocationActivity activity) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (activity == defaultNavigationLocationActivity) {
        // 既定へ戻したら保存値を消す。既定を変えたビルドで、古い保存値が
        // 新しい既定を上書きしないようにする。
        await prefs.remove(_key);
      } else {
        await prefs.setString(_key, activity.name);
      }
    } catch (_) {
      // 開発用の設定なので、失敗を航行へ波及させない。
    }
  }
}
