/// 地図に重ねる層の意味と重なり順を1か所へ集約する。
///
/// 地図は3層で読む。**この対応が崩れると、地図から読み取れる意味が変わる。**
///
/// | 層 | 意味 | 描き方 | zIndex |
/// | --- | --- | --- | --- |
/// | 航路レーン(塗り・線) | そこを通ってよい帯 | ごく薄い帯 | 0 |
/// | 航路シェブロン | 進行方向 | 点在する短い線 | 1 |
/// | 監視モードの航跡 | 過去に通った線 | 線 | 5 |
/// | 危険区域(塗り) | **実在する危険** | 塗り | 10 |
/// | 船体領域・掃引外形(線) | **これから通る予測** | 線 | 20 |
/// | 開発者オーバーレイ | 判定形状の確認用 | 線 | 30 |
///
/// - **塗り = 実在する危険。** そこに何かが在る。
/// - **線 = 予測。** 自艇・他艇がこれから通るだけで、そこには何も無い。
/// - **帯 = 通ってよい場所。** 主役ではない背景。
///
/// マーカー(艇アイコン)は Google Maps の仕様上つねにポリゴンより上に出るため、
/// zIndex の指定は不要。
///
/// 注意: ここで扱うのは見た目と重なり順だけ。どの区域を警告対象にするか、
/// どれだけ手前で鳴らすかは従来どおり `lib/config/` と安全判定側が決める。
/// 危険区域そのものの配色は [HazardPalette] が持ち続ける
/// (このファイルからは参照しない)。
library;

import 'package:flutter/material.dart';

/// 航路レーンの帯。いちばん下に敷く背景。
const int laneFillZIndex = 0;

/// 航路の進行方向シェブロン。帯のすぐ上。
const int laneChevronZIndex = 1;

/// 監視モードの航跡。過去の線なので危険区域より下。
const int coachTrailZIndex = 5;

/// 危険区域の塗り。**実在する危険**なので、帯と航跡より必ず上に出す。
const int hazardPolygonZIndex = 10;

/// 船体領域・掃引外形。予測の線であり、危険区域を隠さないよう上に線だけ乗せる。
const int predictionShapeZIndex = 20;

/// 開発者が判定形状を確認するための一時レイヤー。通常は非表示。
const int developerOverlayZIndex = 30;

/// 航路レーン1本分の表示スタイル。
///
/// 表示専用の値であり、安全判定へは渡らない。
@immutable
class LaneStyle {
  /// 輪郭線の色(不透明度込み)。
  final Color strokeColor;

  /// 塗りの色(不透明度込み)。`leg` 不明のときは完全な透明。
  final Color fillColor;

  /// 輪郭線の太さ。橋脚(3)より必ず細くする。
  final int strokeWidth;

  const LaneStyle({
    required this.strokeColor,
    required this.fillColor,
    required this.strokeWidth,
  });

  @override
  bool operator ==(Object other) =>
      other is LaneStyle &&
      strokeColor == other.strokeColor &&
      fillColor == other.fillColor &&
      strokeWidth == other.strokeWidth;

  @override
  int get hashCode => Object.hash(strokeColor, fillColor, strokeWidth);
}

/// 航路レーンの表示色。[isSatellite] は `MapType.hybrid` のとき true。
///
/// **この機能の主役は危険区域であって航路ではない。** レーンは川幅いっぱいの
/// 面積があるため、塗りが少しでも濃いとその下の岸・橋脚・中州の色を全部
/// 濁らせる。線も、危険区域の輪郭(岸 width 1、橋脚 width 3)より目立っては
/// いけない。航路は「言われて初めて気づく程度の、うっすらした帯」に徹する。
///
/// 往路・復路の差は**明度だけ**でつける(往路 = コントラストの強いグレー、
/// 復路 = 弱いグレー)。片方だけ太く・濃くすると、そちらが危険区域より
/// 目立ってしまう。赤は使わない(危険区域の danger 赤と衝突するため)。
///
/// [leg] が null / 不明のときは**無彩色で描く**。描かないのではなく
/// 「向きが不明な航路」として出す(原則1: 機能を止めない)。
///
/// `highContrastMapStyle` を有効にしているときも `normal` 用の色をそのまま
/// 使う。このスタイルは地図側の彩度を落とすので、薄いグレーの帯でも
/// 輪郭は追える。
LaneStyle laneStyleFor({required String? leg, required bool isSatellite}) {
  // 向きが分からないレーンは、往路とも復路とも読めない無彩色にする。
  // 塗りを持たせると「どちらかの帯」に見えてしまうため線だけで示す。
  if (leg != 'outbound' && leg != 'return') {
    return const LaneStyle(
      strokeColor: Color(0x4D9E9E9E), // #9E9E9E alpha 0.30
      fillColor: Colors.transparent,
      strokeWidth: 1,
    );
  }
  final isOutbound = leg == 'outbound';
  if (isSatellite) {
    // 航空写真は背景が暗いので、往路を明るいグレーにするとコントラストが立つ。
    return isOutbound
        ? const LaneStyle(
            strokeColor: Color(0x73ECEFF1), // #ECEFF1 alpha 0.45
            fillColor: Color(0x0AECEFF1), // #ECEFF1 alpha 0.04
            strokeWidth: 2,
          )
        : const LaneStyle(
            strokeColor: Color(0x7378909C), // #78909C alpha 0.45
            fillColor: Color(0x0A78909C), // #78909C alpha 0.04
            strokeWidth: 2,
          );
  }
  // 通常地図は背景が明るいので、往路を暗いグレーにするとコントラストが立つ。
  return isOutbound
      ? const LaneStyle(
          strokeColor: Color(0x6637474F), // #37474F alpha 0.40
          fillColor: Color(0x0D607D8B), // #607D8B alpha 0.05
          strokeWidth: 2,
        )
      : const LaneStyle(
          strokeColor: Color(0x6690A4AE), // #90A4AE alpha 0.40
          fillColor: Color(0x0DB0BEC5), // #B0BEC5 alpha 0.05
          strokeWidth: 2,
        );
}
