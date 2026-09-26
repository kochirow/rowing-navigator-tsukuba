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
  // 固定の危険区域(橋・橋脚・中州・流木・杭)は琥珀の細線+淡い塗りに揃える。
  // 岸は常にそこにある背景なので、白の細線+ごく淡い塗りで川の形だけ示す。
  // 見た目だけの差で、警告対象・しきい値は変えない。
  // ---------------------------------------------------------------

  /// 夜の配色の基準色。
  static Color nightColorOf(String category) => switch (category) {
        'shore' => const Color(0xFFFFFFFF),
        _ => NavPalette.caution,
      };

  /// 夜の配色の輪郭線。
  static Color nightStrokeColorOf(String category) =>
      nightColorOf(category).withValues(
        alpha: category == 'shore' ? 0.18 : 0.8,
      );

  /// 夜の配色の塗り。岸はごく淡く、ほかは明るい地図より控えめにする
  /// (暗い背景では同じ不透明度でも強く見える)。
  static Color nightFillColorOf(String category, {bool isTemporary = false}) {
    final base = switch (category) {
      'shore' => 0.04,
      'bridge' || 'curve' || 'reverse' => 0.12,
      'bridgePier' || 'pile' => 0.45,
      _ => 0.22,
    };
    return nightColorOf(category).withValues(
      alpha: isTemporary ? (base + 0.10).clamp(0.0, 1.0) : base,
    );
  }
}
