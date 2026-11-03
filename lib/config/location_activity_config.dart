// =====================================================
// 航行中の位置取得の用途指定(iOS の CLActivityType)
// =====================================================
//
// 根拠: docs/要件定義_2026-11-03_実機ログとレビューに基づく改善.md R7。
//
// - iOS では漕いでいる最中に方位精度が±180°(方位が使えない)になる測位が多く、
//   2026-10-30 から位置の変化で方位を求め直している(gnss_motion_validity.dart)。
// - 用途指定を `fitness` から水上の航行向けの `maritime` に変えると、方位を失う
//   割合が下がる可能性がある。Apple は精度への影響を公表しておらず、実機で測る。
// - 誰がいつアプリを使うかは事前に決められないので、端末ごとに割り振る比較はせず、
//   全端末の既定を一斉に切り替えて前後のログで比べる(2026-11-03 利用者判断)。
//   悪ければ次のビルドで既定を `fitness` に戻す。
// - `maritime` が効くのは、iOS 27 の SDK で作り、iOS 27 以上の端末で動かしたとき
//   だけ。それ以外の iOS では geolocator_apple が `otherNavigation` に切り替える
//   (geolocator_apple 2.4.0)。Android は用途指定の影響を受けない。
// - 監視者の位置(陸上を歩く・自転車で追う)は対象外で、`fitness` のまま。

/// 航行中の位置取得に使う用途指定。
enum NavigationLocationActivity {
  /// 水上の航行向け(iOS 27 未満は otherNavigation)。
  maritime,

  /// 2026-11-03 までの既定。運動向け。
  fitness;

  static NavigationLocationActivity? fromName(String? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// リリース版の既定。悪化したら `fitness` に戻す(R7-4)。
const defaultNavigationLocationActivity = NavigationLocationActivity.maritime;

/// `maritime` が効く最初の iOS のメジャー版。SDK も同じ版以上が要る。
const maritimeActivityMinimumIosMajorVersion = 27;

/// 同梱している geolocator_apple の版。診断ログに残し、どの版の挙動かを
/// ログだけで分かるようにする。pubspec.lock と食い違うとテストが落ちる。
const geolocatorAppleVersion = '2.4.3';

/// 実際に効く種類を、指定・端末の iOS の版・アプリを作った SDK から決める。
///
/// [iosMajorVersion] や [sdkMajorVersion] が分からない(null)ときは、効いた種類も
/// 分からないので null を返す。推測で `maritime` と書かない。
String? effectiveLocationActivityName({
  required NavigationLocationActivity requested,
  required bool isIos,
  int? iosMajorVersion,
  int? sdkMajorVersion,
}) {
  if (!isIos) return 'notApplicable';
  if (requested == NavigationLocationActivity.fitness) return 'fitness';
  if (iosMajorVersion == null || sdkMajorVersion == null) return null;
  return iosMajorVersion >= maritimeActivityMinimumIosMajorVersion &&
          sdkMajorVersion >= maritimeActivityMinimumIosMajorVersion
      ? 'maritime'
      : 'otherNavigation';
}

/// "26.6.2" や "iphoneos27.0" から先頭のメジャー版を取り出す。読めなければ null。
int? leadingMajorVersion(String? text) {
  if (text == null) return null;
  final match = RegExp(r'(\d+)').firstMatch(text);
  return match == null ? null : int.tryParse(match.group(1)!);
}
