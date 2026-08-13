import 'package:shared_preferences/shared_preferences.dart';

import '../types/boat_type.dart';

class NavigationDefaults {
  final String displayName;
  final BoatType boatType;
  final int seatPosition;
  final bool strokeRateEnabled;

  /// 航路の断面インジケータを出すか。既定は false。
  ///
  /// 中央線からの位置は地図でも読めるので、必要な人だけが出す補助表示に
  /// する。既定で出すと、計器・警告バナーと上部を取り合うだけになる。
  final bool laneCrossSectionEnabled;

  const NavigationDefaults({
    required this.displayName,
    required this.boatType,
    required this.seatPosition,
    required this.strokeRateEnabled,
    required this.laneCrossSectionEnabled,
  });
}

/// 出艇のたびに同じ名前・艇種・座席を入力し直さなくて済むよう、
/// 直前に確定した値だけを端末内へ保存する。
///
/// AccountDataDeletionServiceのSharedPreferences全消去対象なので、
/// アカウントとデータの削除後に値が残ることはない。
class NavigationDefaultsService {
  static const _displayNameKey = 'navigation_display_name_v1';
  static const _boatTypeKey = 'navigation_boat_type_v1';
  static const _seatPositionKey = 'navigation_seat_position_v1';
  static const _strokeRateEnabledKey = 'navigation_stroke_rate_enabled_v1';
  static const _laneCrossSectionEnabledKey =
      'navigation_lane_cross_section_enabled_v1';

  Future<NavigationDefaults?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final displayName = prefs.getString(_displayNameKey);
    final rawBoatType = prefs.getString(_boatTypeKey);
    final seatPosition = prefs.getInt(_seatPositionKey);
    if (displayName == null ||
        displayName.isEmpty ||
        rawBoatType == null ||
        seatPosition == null) {
      return null;
    }
    BoatType? boatType;
    for (final value in BoatType.values) {
      if (value.name == rawBoatType) {
        boatType = value;
        break;
      }
    }
    if (boatType == null) return null;
    return NavigationDefaults(
      displayName: displayName,
      boatType: boatType,
      seatPosition: seatPosition,
      // 未保存の端末ではSPM(レート)計測を既定で有効にする。
      // 明示的にオフを保存した利用者の選択は維持する。
      strokeRateEnabled: prefs.getBool(_strokeRateEnabledKey) ?? true,
      // 断面インジケータは補助表示なので、未選択の端末では出さない。
      laneCrossSectionEnabled:
          prefs.getBool(_laneCrossSectionEnabledKey) ?? false,
    );
  }

  Future<void> save({
    required String displayName,
    required BoatType boatType,
    required int seatPosition,
    bool strokeRateEnabled = true,
    bool laneCrossSectionEnabled = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setString(_displayNameKey, displayName),
      prefs.setString(_boatTypeKey, boatType.name),
      prefs.setInt(_seatPositionKey, seatPosition),
      prefs.setBool(_strokeRateEnabledKey, strokeRateEnabled),
      prefs.setBool(_laneCrossSectionEnabledKey, laneCrossSectionEnabled),
    ]);
  }

  /// 航行中の表示切替だけを保存する。
  Future<void> saveLaneCrossSectionEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_laneCrossSectionEnabledKey, enabled);
  }
}
