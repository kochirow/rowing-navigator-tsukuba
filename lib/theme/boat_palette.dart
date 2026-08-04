import 'package:flutter/material.dart';

/// 艇そのものの表示色を一元管理する。
///
/// 危険区域の色は [HazardPalette]、航路レーンの色は `laneStyleFor` が持つ。
/// ここが扱うのは「水の上を動いている艇」の色だけである。
///
/// **すべて表示専用。** 安全判定・衝突評価・送信payloadへは渡さない。
class BoatPalette {
  const BoatPalette._();

  /// 自艇の色。**赤はここだけが使う。**
  ///
  /// 航行中の漕手が一瞥で読み取るのは「自分／他艇／向き／近さ」で、
  /// 誰かではない。赤を1つに限ることで、自他の切り分けが最速になる。
  static const Color myBoat = Color(0xFFF44336);

  /// 航行モードの他艇の色。
  ///
  /// 以前は青だったが、通常地図の水面(淡い水色)と同系で、川の上に乗せると
  /// 沈んで見える。かといって赤系・橙系は危険区域(岸・橋脚・橋)の意味色
  /// なので使えない。**濃い青みグレー**は、水面・陸地・航空写真のいずれの
  /// 背景からも浮き、危険色とも混ざらない。
  ///
  /// 航路レーンの帯(`laneStyleFor`)も無彩色だが、あちらは alpha 0.40 の
  /// 細い線で、白縁付きの不透明な艇印とは濃さが桁違いに違う。
  ///
  /// **航行モードでは他艇を艇ごとに色分けしない。** 12色を暗記させないと
  /// 意味を持たない情報であり、赤=自艇の特別扱いも薄める。誰かを知りたい
  /// ときのために名前ラベルを常時出してある。
  static const Color otherBoat = Color(0xFF263238);

  /// 監視モードで艇ごとに割り当てる識別色。
  ///
  /// 監視者は陸上で端末を操作でき、複数艇を並行して追うのが仕事そのもの
  /// なので、航行中とは逆に個体識別が主目的になる(DESIGN_PRINCIPLES 1.3)。
  /// とくに航跡は、桜川では全艇がほぼ同じ線上を往復して必ず重なるため、
  /// 色以外に「この折り返しは誰か」を復元する手段がない。
  ///
  /// 選び方:
  /// - **赤・橙は入れない。** 危険区域(岸・橋脚・橋)と警告の色であり、
  ///   艇に使うと「その艇が危ない」と読めてしまう。
  /// - 明度を暗め〜中に揃える。白縁(`getBoatHomePlateBitmapDescriptor`)が
  ///   効き、通常地図でも航空写真でも輪郭が追える。
  /// - 並び順は色相が隣り合わないようにしてある。衝突時に次の番号へ
  ///   ずらす([assignBoatTrackColors])ため、隣どうしが似ていると
  ///   ずらした意味がなくなる。
  static const List<Color> trackPalette = [
    Color(0xFF1565C0), // 青
    Color(0xFF2E7D32), // 緑
    Color(0xFFAD1457), // マゼンタ
    Color(0xFF827717), // オリーブ
    Color(0xFF00838F), // シアン
    Color(0xFF6A1B9A), // 紫
    Color(0xFF558B2F), // 黄緑
    Color(0xFF6D4C41), // 茶
    Color(0xFF00796B), // ティール
    Color(0xFF4527A0), // 藍紫
  ];

  /// 航跡ポリラインの不透明度。
  ///
  /// 色で艇を見分けるのが目的なので、以前の 0.6 では色が背景に薄まって
  /// 隣の色と区別できない。一方で不透明にすると、下にある危険区域の
  /// 塗りを線が横切って消す。3pxの線として色が読める最小限に留める。
  static const double trailOpacity = 0.8;
}

/// 艇IDから安定した索引を作る(FNV-1a 32bit)。
///
/// `String.hashCode` を使わないのは、値がDartのバージョンや実行ごとに
/// 変わりうるためで、そうなると同じ艇の色がアプリ更新で入れ替わる。
int boatColorHash(String boatId) {
  var hash = 0x811c9dc5;
  for (final unit in boatId.codeUnits) {
    hash ^= unit & 0xff;
    hash = (hash * 0x01000193) & 0xffffffff;
    // 2バイト目も混ぜて、末尾1文字違いのIDが同じ色に寄らないようにする。
    hash ^= (unit >> 8) & 0xff;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

/// 監視中の艇へ識別色を割り当てる。
///
/// - **同じ艇には常に同じ色**を返す(艇IDのハッシュが起点)。監視を開始し直し
///   ても、端末が違っても色は変わらない。
/// - **同時に見えている艇どうしは色が重ならない。** ハッシュが衝突したら
///   次の空き番号へずらす。ずれるのは衝突した艇だけなので、艇が1隻増減
///   しても大半の艇は色を保つ。
/// - 艇数がパレットの色数を超えたら、重複を許してハッシュの色へ戻す。
///   色分けを諦めても表示は続ける(原則1)。名前ラベルは常に出ている。
///
/// 純関数。入力の順序に依存しないよう艇IDでソートしてから割り当てる。
Map<String, Color> assignBoatTrackColors(Iterable<String> boatIds) {
  final palette = BoatPalette.trackPalette;
  final sorted = boatIds.toSet().toList()..sort();
  final assigned = <String, Color>{};
  final used = <int>{};
  for (final boatId in sorted) {
    final start = boatColorHash(boatId) % palette.length;
    var index = start;
    if (used.length < palette.length) {
      while (used.contains(index)) {
        index = (index + 1) % palette.length;
      }
      used.add(index);
    }
    assigned[boatId] = palette[index];
  }
  return assigned;
}
