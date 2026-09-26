import 'package:flutter/material.dart';

/// 航行中の画面だけで使う色(表示専用)。
///
/// 航行中はアプリのテーマ(明色/暗色)によらず「夜の配色」に固定する。
/// 画面を常時点灯するので、OLED では黒い画素ほど電池を使わない
/// (明るさ100%で表示の電力が39〜47%減る。Purdue大 2021)。屋外は自動調光で
/// 明るさが上がるので効く。
///
/// 色の役割は1つずつに絞る(航空機の表示基準 FAA AC 25-11B に倣い6色以内)。
///
/// | 色 | 使う物 |
/// | --- | --- |
/// | 白 | 計器の数字、自艇、自艇の予測線 |
/// | 赤 | 他艇(`BoatPalette.otherBoat`)、警告の画面の端の点滅 |
/// | 琥珀 | 固定の危険区域、能力低下(GPS弱いなど) |
/// | ティール | ワークアウトの WORK 中だけ(控えめに) |
/// | 紺・黒 | 水面・陸 |
///
/// 詳しい経緯は docs/design_notes/2026-09-25_画面刷新_試作v1.md の §11〜§19。
class NavPalette {
  const NavPalette._();

  /// 計器カードの面。純黒。
  static const Color surface = Color(0xFF000000);

  /// 計器1つずつの枠の面。
  static const Color cell = Color(0xFF0C1116);

  /// 枠の縁・区切り線。
  static const Color line = Color(0xFF1F2831);

  /// 計器の数字。
  static const Color value = Color(0xFFFFFFFF);

  /// 単位・ラベル。
  static const Color label = Color(0xFF9AA6B3);

  /// 測位待ちなど、値が無いときの数字。
  static const Color valueMuted = Color(0xFF6B7682);

  /// 操作ボタンの文字・線(追従を止めているとき、メニュー、終了)。
  static const Color control = Color(0xFFC9D3DC);

  /// 能力低下・固定の危険区域の琥珀。
  static const Color caution = Color(0xFFFFB547);

  /// 警告の画面の端の点滅。
  static const Color alert = Color(0xFFFF2828);

  /// ワークアウトの WORK 中だけに控えめに使うティール。
  static const Color work = Color(0xFF35D6C8);

  /// WORK 中の枠の面(ティールをごく薄く混ぜた黒)。
  static const Color workCell = Color(0xFF0B1A1C);

  /// 自艇の予測線(停止距離=実線、警告距離=破線で区別する)。
  static const Color selfPrediction = Color(0xFFFFFFFF);
}
