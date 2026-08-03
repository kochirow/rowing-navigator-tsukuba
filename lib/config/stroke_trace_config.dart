// =====================================================
// 1ストロークの艇速変化グラフ(表示)と、監視端末への共有の設定値
//
// 前提: 加速度センサは stroke_rate_config.dart の 50Hz でしか動かさない。
// ここの値は「すでに手元にある信号を、どう描き・どれだけ送るか」だけを決める。
// センサーの追加購読・サンプリング増加は行わない(電池を増やさないため)。
// =====================================================

/// グラフ用に保持する間引き後のサンプリングレート [Hz]。
///
/// 50Hzの生サンプルは積分にだけ使い、リングバッファへは1点おきに入れる。
/// 25Hzあれば 40ms 刻みで、1ストローク(最短約0.9秒)でも22点が残る。
/// 画面上の1点は概ね1px未満になるため、これ以上増やしても見た目は変わらない。
const strokeTraceSampleHz = 25;

/// リングバッファの長さ [秒]。画面に出す2ストローク(最長10秒)に、
/// 再中心化と共有用の切り出しの余裕を足した値。
const strokeTraceBufferSeconds = 14;

/// 画面に出す時間窓 [秒]。原則「直近2ストローク」。
/// SPMが取れていないあいだは [strokeTraceFallbackWindowSeconds] を使う。
const strokeTraceStrokesOnScreen = 2;
const strokeTraceMinimumWindowSeconds = 3.0;
const strokeTraceMaximumWindowSeconds = 10.0;
const strokeTraceFallbackWindowSeconds = 6.0;

/// 連続積分のハイパス時定数 [秒]。
///
/// 加速度のバイアスをそのまま積分すると速度が際限なく流れる。ストローク周期
/// (1.5〜5秒)より十分長い時定数で漏らすことで、周期成分の振幅をほとんど
/// 落とさずに直流だけを捨てる。残る定常オフセットは、描画時に窓平均を
/// 引くことで消える(= 窓の平均艇速はGNSS艇速に一致する)。
const strokeTraceHighPassSeconds = 8.0;

/// 縦軸の最小レンジ [m/s]。
///
/// 停止中やごく静かな漕ぎで自動スケールを効かせると、ノイズが全画面に
/// 拡大されて「大きく変動している」ように見える。実際の変動がこれ未満の
/// ときは軸を固定し、平らな線として正直に見せる。
const strokeTraceMinimumSpanMetersPerSecond = 0.6;

/// 縦軸レンジに足す上下の余白の割合。
const strokeTraceVerticalPaddingFraction = 0.12;

/// グラフの再描画レート [Hz]。
///
/// 心電図のように流すには連続再描画が要るが、60fpsは要らない。25Hzの
/// 記録レートに合わせておけば、新しい点が来るたびに1回描くことになる。
const strokeTraceRepaintHz = 25;

// ----------------------------------------------------
// 監視端末への共有
// ----------------------------------------------------

/// 共有する1ストロークあたりの波形サンプル数。
///
/// 48点あれば 40spm(周期1.5秒)でも31ms刻みで、キャッチの谷と
/// フィニッシュの山を潰さずに再現できる。1点1バイトなのでbase64で64文字。
const sharedStrokeWaveformSamples = 48;

/// 波形1点の量子化幅 [m/s]。int8(±127)で ±1.27m/s を表す。
///
/// 実測のストローク内変動は 8+ で ±0.4m/s、1x でも ±0.8m/s 程度なので
/// 飽和しない。飽和した場合は端が潰れるだけで、値の意味は壊れない。
const strokeWaveformQuantumMetersPerSecond = 0.01;
const strokeWaveformMaximumQuantum = 127;

/// 共有の最短書込間隔 [ミリ秒]。
///
/// database.rules.json の `stroke_traces` レート制限(1700ms)より大きく
/// とる。高レートでは1ストロークごとに送らず間引かれるが、波形の形は
/// 1ストロークで完結しているため、間引いても各ストロークは完全なまま。
const sharedStrokeTraceMinimumIntervalMs = 1900;

/// 監視端末が受信した波形を「今の漕ぎ」として扱う上限 [秒]。
///
/// 超えたら古い波形を描き続けず、途絶として表示する。
/// 空白を「変動がなかった」と読ませない(原則6)。
const sharedStrokeTraceFreshnessSeconds = 12;

/// 監視端末が連結して保持する直近ストローク数。
/// 2ストローク表示 + 到着ジッタの余裕で4本。
const sharedStrokeTraceHistoryStrokes = 4;
