/// 高コントラスト表示用の地図スタイル。
///
/// 直射日光の下では、地図の緑・青と危険区域の赤・茶の差が潰れて読めなくなる。
/// 地図側の彩度を落として明るくすると、彩度を持ったまま重なる危険区域・艇・
/// 航跡だけが浮き上がる。
///
/// 注意: Google Maps のスタイルは `MapType.normal` にだけ効く。航空写真
/// (hybrid)では無視されるため、切り替えても表示は変わらない。
///
/// 地図を手で動かした後に追従へ戻す待機時間。2〜10秒の範囲に保つ。
/// 明示的に「追跡」をオフにした場合には使わない。
const mapAutoRecenterDelay = Duration(seconds: 3);
const mapAutoRecenterMinimumDelay = Duration(seconds: 2);
const mapAutoRecenterMaximumDelay = Duration(seconds: 10);

/// 艇種別の矢羽アイコン（Canvas描画）の見た目を決める定数。
const boatArrowTailNotchRatio = 0.22;
const boatArrowOutlineWidthLogicalPixels = 1.5;
// 縮小時だけ見失わない最小長。通常の航行縮尺では実長を優先し、
// 衝突判定ポリゴンより小さく見えるよう従来の16pxから下げる。
const minBoatMarkerLengthPixels = 8;

bool isValidMapAutoRecenterDelay(Duration value) =>
    value >= mapAutoRecenterMinimumDelay &&
    value <= mapAutoRecenterMaximumDelay;

const highContrastMapStyle = '''
[
  {"elementType":"geometry","stylers":[{"saturation":-100},{"lightness":25}]},
  {"elementType":"labels.icon","stylers":[{"visibility":"off"}]},
  {"elementType":"labels.text.fill","stylers":[{"saturation":-100},{"lightness":-25}]},
  {"elementType":"labels.text.stroke","stylers":[{"saturation":-100},{"lightness":70}]},
  {"featureType":"poi","stylers":[{"visibility":"off"}]},
  {"featureType":"transit","stylers":[{"visibility":"off"}]},
  {"featureType":"road","elementType":"geometry","stylers":[{"saturation":-100},{"lightness":45}]},
  {"featureType":"landscape","elementType":"geometry","stylers":[{"saturation":-100},{"lightness":45}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"saturation":-100},{"lightness":35}]}
]
''';
