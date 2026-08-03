/// 待機中(航行も監視もしていない)の初期倍率。従来値。
///
/// 起動直後は自分がどこにいるかを掴む段階なので、川だけでなく周囲の
/// 目印(橋・艇庫・道路)が見えるほうがよい。
const initialMapZoomLevel = 18.0;

/// 航行開始の瞬間だけ適用する倍率。
///
/// 桜川の川幅は40〜50m・狭所35m(DESIGN_PRINCIPLES 1.1)。北緯36度・
/// 論理幅390ptで zoom 19 の画面幅は約94mとなり、川幅の約2倍が入る。
/// 「自分の岸」と「対向艇の岸」が同時に見える最小の倍率であり、
/// 右側通行の判断に必要な情報がちょうど収まる。
/// 縦方向は約203m見えるため、予測地平(10秒×5m/s＝50m先)は必ず画面内に入る。
/// これ以上寄せる(zoom 20 ＝ 画面幅47m)と両岸が見切れる。
///
/// **適用するのは航行開始の1回だけ。** 以後は利用者がピンチで選んだ倍率を
/// そのまま保つ(原則2: 使い方は使い手が決める)。
const navigationStartZoomLevel = 19.0;

/// 監視開始の瞬間だけ適用する倍率。
///
/// 監視者は陸上で端末を操作できるため、拡大より俯瞰が要る(Wakelockを
/// 航行中だけに限るのと同じ理屈: DESIGN_PRINCIPLES 1.3・1.4)。
/// 同時に2〜12艇が数百m に散らばるので広く取る。
const watchStartZoomLevel = 16.5;

/// 監視中に「全艇」ボタンで寄せるとき、艇が1隻しかいない場合の倍率。
///
/// 1点だけでは bounds が潰れ、Google Maps が最大倍率まで寄せてしまう。
/// 艇の周囲が読める程度に留める。
const watchSingleBoatZoomLevel = 17.0;

/// 監視中に艇一覧・異常チップから1艇へ寄るときの下限倍率。
///
/// 引きすぎているときだけ寄せ、すでに寄っているなら引き戻さない。
const watchFocusMinimumZoomLevel = 18.0;

/// 航行中に自艇を画面のどこへ置くか(画面上端からの比率)。
///
/// 漕手は後ろ向きに座り進行方向が見えない。地図は進行方向が上になるよう
/// 回転している(`rowingMapBearing`)ので、自艇を下へ寄せるとそのぶん
/// 前方の見通しが増える。0.667(下から1/3)で前方が約100m→約135mになる。
///
/// Google Maps はパディングを除いた領域の中心にカメラのターゲットを置く。
/// 上パディング P・画面高さ H のときターゲットの画面Yは (P + H) / 2 なので、
/// この比率 r にするには P = (2r - 1) * H を入れる。
const navigationSelfBoatScreenRatio = 0.667;

/// 地図を手で動かした後に追従へ戻す待機時間。2〜10秒の範囲に保つ。
/// 明示的に「追跡」をオフにした場合には使わない。
const mapAutoRecenterDelay = Duration(seconds: 3);
const mapAutoRecenterMinimumDelay = Duration(seconds: 2);
const mapAutoRecenterMaximumDelay = Duration(seconds: 10);

/// 艇種別のホームベース型アイコン（Canvas描画）の見た目を決める定数。
const boatArrowOutlineWidthLogicalPixels = 1.5;
// 縮小時でも見失わないホームベース型アイコンの論理px範囲。
//
// 実艇の長さに連動させつつ、iPhone上で視認できる36〜56ptへ収める。
// Canvas描画が使えずPNGへ縮退したときも同じ下限を使うため、代替経路だけ
// 数pxになって自艇・他艇が消えたように見えることを防ぐ。
const minBoatMarkerLengthPixels = 36;
const maxBoatMarkerLengthPixels = 56;

bool isValidMapAutoRecenterDelay(Duration value) =>
    value >= mapAutoRecenterMinimumDelay &&
    value <= mapAutoRecenterMaximumDelay;

/// 高コントラスト表示用の地図スタイル。
///
/// 直射日光の下では、地図の緑・青と危険区域の赤・茶の差が潰れて読めなくなる。
/// 地図側の彩度を落として明るくすると、彩度を持ったまま重なる危険区域・艇・
/// 航跡だけが浮き上がる。
///
/// 注意: Google Maps のスタイルは `MapType.normal` にだけ効く。航空写真
/// (hybrid)では無視されるため、切り替えても表示は変わらない。
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
