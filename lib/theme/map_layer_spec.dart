/// 地図に重ねる層の意味と重なり順を1か所へ集約する。
///
/// 地図は層で読む。**この対応が崩れると、地図から読み取れる意味が変わる。**
///
/// | 層 | 意味 | 描き方 | zIndex |
/// | --- | --- | --- | --- |
/// | 航路の中央線 | **越えない取り決め** | 白い破線(暗い縁取り) | 2 |
/// | 桟橋エリア | **場所の宣言**(危険ではない) | 白い破線の輪郭・塗りなし | 3 |
/// | 監視モードの航跡 | 過去に通った線 | 線 | 5 |
/// | 危険区域(塗り) | **実在する危険** | 塗り | 10 |
/// | 船体領域・掃引外形(線) | **これから通る予測** | 線 | 20 |
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
/// ## 自艇まわりの図形を作り替えて、元へ戻した記録(2026-08-05)
///
/// 「入れ子の3枚が何を示す図か分からない」という出発点から、2案を実機で
/// 試して**いずれも採用せず、元の3枚へ戻した**。同じ道をもう一度たどら
/// ないよう、試したことと戻した理由をここに残す。
///
/// 現行(=元どおり)の3枚は `home_map_screen.dart` の該当箇所にある。
///   ① 船体領域(t=0) … 黒の細線 + ごく薄い塗り。いま艇が在る場所
///   ② 掃引外形(凸包) … 橙 `#F9A825` の細線。どこまで届くか
///   ③ 停止距離ライン … 赤 `#D32F2F` の細線の輪。どこまでなら止まれるか
///
/// **試案1: 均一な太さの予測経路 + 停止距離の横棒。**
/// 3枚を線1本と横棒1つへ減らした。実機で「まだ何の図か分からない」。
/// 均一な太さの線は起点と向きを形で示せず、横棒1本には意味の手がかりが
/// 無かった(記号を覚えていないと「停止距離」という読み方が出てこない)。
///
/// **試案2: 先細りのビーム1つ(長さ = 停止距離)。**
/// 経路可視化の研究で先細りが向きを伝える性能に優れること、Google マップの
/// 位置ビームが懐中電灯の比喩で理解されることを根拠に、図形を1つへ絞った。
/// 低速で幅が長さを追い越す不具合も直した。
///
/// **それでも戻した理由(利用者判断)。**
///   1. **元のほうが見た目が良い。** 橙と赤の細い線は、地図の上で
///      主張しすぎずに形が読める。
///   2. **ビームは存在感が過剰。** 面を持ち、輪郭も太いため、自艇の
///      まわりが常に塞がって見える。地図は水面と危険区域を見るためのもので、
///      自艇の予測がその一等地を占めてよい理由は無い。
///   3. 「読み取りやすさ」を上げるために図形を大きく・濃くするのは、
///      **原則4(過剰は安全機能の破壊)の視覚版**を自分で踏んでいた。
///
/// **次に触るときの指針。** 「何の図か分からない」を、図形を**足す・太く
/// する・塗る**方向で解こうとしないこと。細さと控えめさは、この画面では
/// 失ってはいけない性質である。解くとしたら、凡例・初回の説明・設定画面
/// といった**地図の外側**か、図形を減らす方向で。
library;

import 'package:flutter/material.dart';

/// 航路の中央線。取り決めの線なので、実在する危険と航跡より下に敷く。
const int channelDividerZIndex = 2;

/// 桟橋エリアの輪郭。場所の宣言であり、実在する危険ではない。
/// 中央線と同じ「取り決め」の層に置き、危険区域の塗りより下に敷く。
const int mooringAreaZIndex = 3;

/// 監視モードの航跡。過去の線なので危険区域より下。
const int coachTrailZIndex = 5;

/// 危険区域の塗り。**実在する危険**なので、中央線と航跡より必ず上に出す。
const int hazardPolygonZIndex = 10;

/// 船体領域・掃引外形。予測の線であり、危険区域を隠さないよう上に線だけ乗せる。
const int predictionShapeZIndex = 20;

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

/// 桟橋エリア1つぶんの表示スタイル。
///
/// **塗らない。** 塗り = 実在する危険、という対応を崩さないため
/// (このファイル冒頭の表)。桟橋エリアは水面であり、そこに何かが在る
/// わけではない。輪郭を破線で示すだけにする。
///
/// 色は中央線と同じ「白い芯 + 暗い縁取り」を使う。色相を割り当てないのは
/// 中央線と同じ理由で、赤・橙・青・紫は [HazardPalette] が使い切っている。
/// 中央線より細く・破線を短くして、主役を取らないようにする。
@immutable
class MooringAreaStyle {
  final Color coreColor;
  final int coreWidth;
  final Color casingColor;
  final int casingWidth;
  final int dashLengthPixels;
  final int gapLengthPixels;

  const MooringAreaStyle({
    required this.coreColor,
    required this.coreWidth,
    required this.casingColor,
    required this.casingWidth,
    required this.dashLengthPixels,
    required this.gapLengthPixels,
  });

  @override
  bool operator ==(Object other) =>
      other is MooringAreaStyle &&
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

/// 桟橋エリアの表示色。[isSatellite] は `MapType.hybrid` のとき true。
MooringAreaStyle mooringAreaStyleFor({required bool isSatellite}) {
  if (isSatellite) {
    return const MooringAreaStyle(
      coreColor: Color(0xD9FFFFFF), // 白 alpha 0.85
      coreWidth: 2,
      casingColor: Color(0x80000000), // 黒 alpha 0.50
      casingWidth: 4,
      dashLengthPixels: 10,
      gapLengthPixels: 8,
    );
  }
  return const MooringAreaStyle(
    coreColor: Color(0xD9FFFFFF), // 白 alpha 0.85
    coreWidth: 2,
    casingColor: Color(0x8C263238), // #263238 alpha 0.55
    casingWidth: 4,
    dashLengthPixels: 10,
    gapLengthPixels: 8,
  );
}
