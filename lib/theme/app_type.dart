import 'package:flutter/material.dart';

/// 文字の大きさの型。**12px 未満は使わない**(グラフの軸の目盛りだけ 11px)。
///
/// 以前は画面ごとに 9.5〜52px の21種類が散らばっていた。新しい画面はここから選ぶ。
/// 数字は等幅(`tabularFigures`)にして、値が変わっても桁の位置がずれないようにする。
class AppType {
  const AppType._();

  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  // ---- 航行中の計器(重要度: ペース > レート > 下半分) ----
  static const double navPace = 76;
  static const double navRate = 70;
  static const double navLowerLarge = 46;
  static const double navLowerSmall = 36;
  static const double navWorkoutMain = 66;
  static const double navWorkoutSub = 44;

  /// 計器の単位(各枠の右下)。
  static const double navUnit = 13;

  // ---- 一般の画面 ----
  static const double display = 56;
  static const double headline = 26;
  static const double title = 18;
  static const double body = 15;
  static const double label = 13;
  static const double caption = 12;

  /// 大きな数字(等幅・太字)。
  static TextStyle number(double size, {Color? color}) => TextStyle(
        fontSize: size,
        fontWeight: FontWeight.w800,
        height: 1.0,
        letterSpacing: -size * 0.02,
        color: color,
        fontFeatures: _tabular,
      );
}
