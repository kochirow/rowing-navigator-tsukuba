import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'nav_palette.dart';

/// 危険区域の種類ごとの色を一元管理する。
///
/// 警告バナーと地図ポリゴンが別々に色を決めていると、バナーは「流木」と
/// 言っているのに地図では岸と同じ赤、という食い違いが起きる。表示は
/// どちらもここを参照し、カテゴリ名(`StaticObstacleKind.name` と同じ文字列)
/// をキーにする。
///
/// 注意: ここで扱うのは見た目だけ。どの区域を警告対象にするか、どれだけ
/// 手前で鳴らすかは従来どおり `lib/config/` と安全判定側が決める。
class HazardPalette {
  const HazardPalette._();

  /// カテゴリの基準色。バナーのチップ背景と地図の輪郭線に使う。
  static Color colorOf(BuildContext context, String category) =>
      switch (category) {
        'shore' => context.colors.danger,
        'bridge' => context.colors.warning,
        'bridgePier' => context.colors.danger,
        'island' => const Color(0xFF8D6E00),
        'driftwood' => const Color(0xFF6D4C41),
        'pile' => const Color(0xFF4E342E),
        'other_boat' => const Color(0xFFAD1457),
        'curve' => context.colors.info,
        'reverse' => const Color(0xFF8E24AA),
        'testZone' => const Color(0xFF00838F),
        _ => const Color(0xFF455A64),
      };

  /// 地図ポリゴンの塗り不透明度。
  ///
  /// 岸は基準線の各辺が長方形へ展開され release でも約310枚になる。同じ濃さで
  /// 塗ると川の両側が一様に赤くなり、本当に避けたい流木や中州がその中へ
  /// 埋もれる。常時そこにある岸は背景として薄く、点在する物体は濃くする。
  static double fillOpacityOf(String category, {bool isTemporary = false}) {
    final base = switch (category) {
      'shore' => 0.18,
      'bridge' || 'curve' || 'reverse' => 0.28,
      'bridgePier' => 0.52,
      'pile' => 0.48,
      _ => 0.45,
    };
    // 現地で見つけて登録された臨時区域は、同じ種類の常設区域より目立たせる。
    return isTemporary ? (base + 0.10).clamp(0.0, 1.0) : base;
  }

  /// 塗りが薄い区域ほど輪郭線を頼りにするため、線は常に不透明寄りにする。
  static Color strokeColorOf(BuildContext context, String category) =>
      colorOf(context, category).withValues(alpha: 0.85);

  /// 岸のように枚数が多い区域は細く、点在する物体は太くする。
  static int strokeWidthOf(String category) => switch (category) {
        'shore' => 1,
        'bridge' || 'curve' || 'reverse' => 2,
        'bridgePier' => 3,
        'pile' => 3,
        _ => 3,
      };

  /// 地図ポリゴンの塗り色。
  static Color fillColorOf(
    BuildContext context,
    String category, {
    bool isTemporary = false,
  }) =>
      colorOf(context, category).withValues(
        alpha: fillOpacityOf(category, isTemporary: isTemporary),
      );

  // ---------------------------------------------------------------
  // 航行中の「夜の配色」(暗い地図)用。
  //
  // 暗い地図では、赤は「衝突に関わるもの(他艇・警告の点滅)」に空ける。
  // 固定の危険区域(橋・橋脚・中州・流木・杭)は琥珀の線+塗りに揃える。
  // 岸は常にそこにある背景なので、白の細線+ごく淡い塗りで川の形だけ示す。
  // 見た目だけの差で、警告対象・しきい値は変えない。
  //
  // 2026-10-06: 危険区域は画面の中を動いてくるので、自艇より見分けやすさを
  // 優先する(利用者決定)。水面を `#17405a` へ明るくしたぶん、琥珀の線を
  // 不透明にし、点在する区域の塗りを濃くした。水面との差は
  // 線 5.45 → 6.23、中州・流木の塗り 1.58 → 1.83、橋脚・杭の塗り 2.66 → 2.88。
  // 橋・カーブ・逆走は毎回通る広い区域なので、塗りは淡いまま線で形を示す。
  // ---------------------------------------------------------------

  /// 夜の配色の基準色。
  static Color nightColorOf(String category) => switch (category) {
        'shore' => const Color(0xFFFFFFFF),
        _ => NavPalette.caution,
      };

  /// 夜の配色の輪郭線。
  static Color nightStrokeColorOf(String category) =>
      nightColorOf(category).withValues(
        // 岸の線は少しだけ濃くする(水面との差 1.70 → 2.26)。岸は約310枚の
        // 長方形なので、濃くしすぎると継ぎ目がはしご状に見える。
        alpha: category == 'shore' ? 0.28 : 1.0,
      );

  /// 夜の配色の塗り。岸はごく淡く、ほかは明るい地図より控えめにする
  /// (暗い背景では同じ不透明度でも強く見える)。
  ///
  /// **岸の塗りは濃くしない。** 岸の区域は水際をまたいで陸側へ15m伸びるので、
  /// 白い塗りを濃くすると黒い陸が灰色に持ち上がり、水面との差が逆に縮む
  /// (0.04 で 1.73、0.12 で 1.41)。陸を見分ける手段は水面の明るさのほうである。
  static Color nightFillColorOf(String category, {bool isTemporary = false}) {
    final base = switch (category) {
      'shore' => 0.04,
      'bridge' || 'curve' || 'reverse' => 0.12,
      'bridgePier' || 'pile' => 0.55,
      _ => 0.32,
    };
    return nightColorOf(category).withValues(
      alpha: isTemporary ? (base + 0.10).clamp(0.0, 1.0) : base,
    );
  }
}
