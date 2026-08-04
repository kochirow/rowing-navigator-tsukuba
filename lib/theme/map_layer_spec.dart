/// 地図に重ねる層の意味と重なり順を1か所へ集約する。
///
/// 地図は層で読む。**この対応が崩れると、地図から読み取れる意味が変わる。**
///
/// | 層 | 意味 | 描き方 | zIndex |
/// | --- | --- | --- | --- |
/// | 航路の中央線 | **越えない取り決め** | 白い破線(暗い縁取り) | 2 |
/// | 監視モードの航跡 | 過去に通った線 | 線 | 5 |
/// | 危険区域(塗り) | **実在する危険** | 塗り | 10 |
/// | 停止距離ビーム | **止まろうとしても行ってしまう先** | 先細りの帯 | 20 |
/// | 開発者オーバーレイ | 判定形状の確認用 | 線 | 30 |
///
/// - **塗り = 実在する危険。** そこに何かが在る。
/// - **実線 = 実在するものの輪郭。** 岸・橋脚・中州の縁。
/// - **破線 = 取り決め。** 物理的には何も無く、越えられる。中央線がこれ。
/// - **線(予測) = 自艇・他艇がこれから通るだけで、そこには何も無い。**
///
/// マーカー(艇アイコン)は Google Maps の仕様上つねにポリゴンより上に出るため、
/// zIndex の指定は不要。
///
/// 注意: ここで扱うのは見た目と重なり順だけ。どの区域を警告対象にするか、
/// どれだけ手前で鳴らすかは従来どおり `lib/config/` と安全判定側が決める。
/// 危険区域そのものの配色は [HazardPalette] が持ち続ける
/// (このファイルからは参照しない)。
///
/// ## 往路・復路の帯(`laneStyleFor`)を廃止した記録
///
/// 以前は往路・復路のポリゴンを、明度差だけをつけたごく薄いグレーの帯として
/// 敷いていた。**現地で「自分がどちら側にいるか分からない」**という判断で
/// 取りやめた(2026-08-04)。理由は濃さではなく、情報の優先順位が
/// 逆転していたことにある。
///
///   1. 漕手が知りたいのは「中央線のどちら側か」の1点だけなのに、
///      いちばん重要な**共有辺(=中央線)**が、外側の辺と同じ太さ・同じ色で
///      引かれていた。画面には縦にグレーの線が3本走り、どれが越えては
///      いけない線か区別できなかった。
///   2. 外側の辺は岸の危険区域(赤の輪郭)とほぼ重なる冗長な線だった。
///   3. 無彩色は、basemap 自身のグレーの線(道路・水域の縁)と混ざった。
///      「危険区域より目立たない」を無彩色で作った結果、地図のノイズに
///      紛れてしまった。
///   4. 面は「どちら側か」に答えられない。往路と復路は同じ形・同じ明度差
///      なので、判断には**2本の境界と自艇の3者**を見比べる必要があった。
///      漕手は後ろ向きで、地図は回転していて、視線を送れるのは1秒未満。
///
/// いまは**中央線を1本だけ**描き、外側の辺は描かない。二者比較
/// (白い破線の左か右か)に落ちる。帯を復活させるなら、上の4点に
/// どう答えるのかを先にここへ書くこと。
///
/// ## 自艇まわりの図形を「ビーム1本」へ絞った記録(2026-08-05)
///
/// もとは艇ごとに「船体領域(塗り) + 掃引外形の凸包(橙) + 停止距離の
/// 閉じた輪(赤)」を同心に重ねていた。実機で**「何を見ているのか分から
/// ない」**という判断で、まず「均一な太さの予測経路 + 停止距離の横棒」へ
/// 置き換え、**それでも読めなかった**ので、いまの形へ作り直した。
///
/// 3枚重ねが読めなかった理由:
///
///   1. 3枚とも「艇を中心とした六角形」で、**区別が形になっていない**。
///      どれが何かは大きさの順序を暗記しないと読めない。
///   2. ①②が塗りを持っていた。上表の「塗り = 実在する危険」に反する。
///   3. 停止距離が `danger` の赤だった。**正常に漕いでいる間ずっと赤い輪が
///      自艇に付いてくる**のは、視覚版の形骸化した警告である(原則4)。
///   4. 他艇ぶんも同じ3枚が出るため、12艇では36枚の六角形が重なった。
///
/// 「線 + 横棒」でも読めなかった理由:
///
///   5. **均一な太さの線は方向を伝えない。** 経路可視化の比較研究では、
///      先細り(tapered)の帯が経路の向きを伝える性能で他を上回る。
///   6. **横棒1本には意味の手がかりが無い。** 「停止距離」という読み方は
///      記号を覚えていないと出てこない。
///   7. 警告時の掃引外形は `generic` の青灰(#455A64)で、地図の灰色に
///      完全に埋もれた。色が状態を表すはずが、何も表していなかった。
///
/// いまは**図形を1つだけにし、その長さ自体に意味を持たせる**。
///
///   - 自艇・他艇から前へ伸びる**先細りのビーム**を1本だけ描く
///   - 長さ = **停止距離**。「いま止まろうとしても、ここまでは行く」
///   - 幅 = 排他領域の幅から先端へ絞る。根元が艇の幅と一致するので、
///     帯が艇から生えて見える(Google マップの位置ビームと同じ比喩)
///   - **警告中はその警告の色に染まる。** バナーが「橋に注意」と言っている
///     とき、光っている帯も同じ色になるので、図と言葉が結びつく
///   - 停止距離の横棒・掃引外形・予測地平の線はすべて廃止した
///
/// 形状は `boat_prediction_overlay_service.dart` が作る(表示専用・純Dart)。
/// 図形を増やすなら、上の7点にどう答えるのかを先にここへ書くこと。
library;

import 'package:flutter/material.dart';

/// 航路の中央線。取り決めの線なので、実在する危険と航跡より下に敷く。
const int channelDividerZIndex = 2;

/// 監視モードの航跡。過去の線なので危険区域より下。
const int coachTrailZIndex = 5;

/// 危険区域の塗り。**実在する危険**なので、中央線と航跡より必ず上に出す。
const int hazardPolygonZIndex = 10;

/// 停止距離ビーム。予測の形であり、危険区域を隠さないよう上に乗せる。
const int predictionShapeZIndex = 20;

/// 自艇・他艇の「止まれない距離」ビーム1本ぶんの表示スタイル。
///
/// **色相では主張しない。** 中央線と同じ理由で、色相は [HazardPalette] が
/// 危険の種類に使い切っている。平常時のビームに赤や橙を割り当てると
/// 「そこに何かが在る」「異常だ」と誤読される。**白の半透明**にする。
/// 危険区域は必ず色相を持つので、無彩色のビームと混ざることはない。
///
/// 自艇と他艇の差は**色相ではなく明度と塗りの有無**でつける。航行中は
/// 艇を色分けしない方針([BoatPalette] 参照)と揃うだけでなく、他艇が
/// 12本並んでも画面が色で埋まらない。
@immutable
class BoatPredictionBeamStyle {
  /// 輪郭の色。
  final Color strokeColor;

  /// 輪郭の太さ。
  final int strokeWidth;

  /// 面の色。**自艇だけが薄く塗られる。**
  ///
  /// 「塗り = 実在する危険」の規則は色相を持つ層の話である。無彩色の
  /// 半透明はビームが艇から生えていることを示すための光であって、
  /// 危険区域として読まれる余地がない。
  final Color fillColor;

  const BoatPredictionBeamStyle({
    required this.strokeColor,
    required this.strokeWidth,
    required this.fillColor,
  });
}

/// ビームの表示色。[isSatellite] は `MapType.hybrid` のとき true。
///
/// [warningColor] に色を渡すと、その色でビームを染める。警告が出ている
/// あいだだけ呼出元が渡す。**バナーが「橋に注意」と言っているとき、
/// 地図で光っている帯も同じ色になる**ので、図と言葉が結びつく。
BoatPredictionBeamStyle boatPredictionBeamStyleFor({
  required bool isSatellite,
  required bool isMyBoat,
  Color? warningColor,
}) {
  if (warningColor != null) {
    return BoatPredictionBeamStyle(
      strokeColor: warningColor.withValues(alpha: 0.95),
      strokeWidth: 4,
      fillColor: warningColor.withValues(alpha: 0.22),
    );
  }
  if (isMyBoat) {
    return BoatPredictionBeamStyle(
      // 航空写真は下地が暗いので、白をわずかに強める。
      strokeColor: isSatellite ? const Color(0xF2FFFFFF) : const Color(0xE6FFFFFF),
      strokeWidth: 3,
      fillColor: isSatellite
          ? const Color(0x40FFFFFF) // 白 alpha 0.25
          : const Color(0x33FFFFFF), // 白 alpha 0.20
    );
  }
  // 他艇は輪郭だけ。存在と向きが読めれば足りる。12艇ぶん塗ると地図が消える。
  return const BoatPredictionBeamStyle(
    strokeColor: Color(0x99FFFFFF), // 白 alpha 0.60
    strokeWidth: 2,
    fillColor: Color(0x00000000),
  );
}

/// ビームの縁取り(casing)。中央線と同じく、芯の下へ一回り太く敷く。
///
/// 白い帯だけだと、地図の白い建物・砂地の上で輪郭が消える。
Color beamCasingColorFor({required bool isSatellite}) => isSatellite
    ? const Color(0xB3000000) // 黒 alpha 0.70
    : const Color(0xA6263238); // #263238 alpha 0.65。中央線と同じ暗色

/// 縁取りの太さは芯より一回り太い。
const int beamCasingExtraWidth = 3;

/// 開発者が判定形状を確認するための一時レイヤー。通常は非表示。
const int developerOverlayZIndex = 30;

/// 航路の中央線1本ぶんの表示スタイル。
///
/// 芯(白)と縁取り(暗色)の2本のポリラインで1本の線を作る。表示専用の値で
/// あり、安全判定へは渡らない。
@immutable
class ChannelDividerStyle {
  /// 芯の色。地図の下地が明るくても暗くても読める白。
  final Color coreColor;

  /// 芯の太さ。
  final int coreWidth;

  /// 縁取りの色。芯の下へ一回り太く敷く。
  final Color casingColor;

  /// 縁取りの太さ。[coreWidth] より必ず太い。
  final int casingWidth;

  /// 破線1本の長さ [px]。
  final int dashLengthPixels;

  /// 破線どうしの間隔 [px]。
  final int gapLengthPixels;

  const ChannelDividerStyle({
    required this.coreColor,
    required this.coreWidth,
    required this.casingColor,
    required this.casingWidth,
    required this.dashLengthPixels,
    required this.gapLengthPixels,
  });

  @override
  bool operator ==(Object other) =>
      other is ChannelDividerStyle &&
      coreColor == other.coreColor &&
      coreWidth == other.coreWidth &&
      casingColor == other.casingColor &&
      casingWidth == other.casingWidth &&
      dashLengthPixels == other.dashLengthPixels &&
      gapLengthPixels == other.gapLengthPixels;

  @override
  int get hashCode => Object.hash(coreColor, coreWidth, casingColor,
      casingWidth, dashLengthPixels, gapLengthPixels);
}

/// 航路中央線の表示色。[isSatellite] は `MapType.hybrid` のとき true。
///
/// **色相では主張しない。** 赤・橙・青・紫は [HazardPalette] が
/// 岸・橋・橋脚・カーブ・逆走に使い切っているので、中央線に色を割り当てると
/// 「そこに何かが在る」と誤読される。かわりに**白い芯 + 暗い縁取り**という
/// 組み合わせで主張する。これは basemap が水面の上に描かない組み合わせで、
/// 通常地図(明るい水色)でも航空写真(暗い)でも同じ見え方になる。
///
/// **破線にするのは意味の区別である。** 実線は実在するものの輪郭(岸・橋脚)、
/// 破線は取り決め(越えられるが越えない線)。道路の中央線と同じ読み方で、
/// 覚え直す必要がない。
///
/// 太さは橋脚(width 3)と同等にとどめる。中央線は主役だが、**実在する危険
/// より太くはしない**。
ChannelDividerStyle channelDividerStyleFor({required bool isSatellite}) {
  if (isSatellite) {
    // 航空写真は下地が暗い。縁取りを黒寄りにして、白い芯を際立たせる。
    return const ChannelDividerStyle(
      coreColor: Color(0xF2FFFFFF), // 白 alpha 0.95
      coreWidth: 3,
      casingColor: Color(0x99000000), // 黒 alpha 0.60
      casingWidth: 5,
      dashLengthPixels: 18,
      gapLengthPixels: 12,
    );
  }
  return const ChannelDividerStyle(
    coreColor: Color(0xF2FFFFFF), // 白 alpha 0.95
    coreWidth: 3,
    // 通常地図の水面(淡い水色)に対しては、黒より青みの暗色のほうが
    // 汚れて見えない。岸の赤とも混ざらない。
    casingColor: Color(0xA6263238), // #263238 alpha 0.65
    casingWidth: 5,
    dashLengthPixels: 18,
    gapLengthPixels: 12,
  );
}
