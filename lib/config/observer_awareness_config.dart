/// 監視者向けの艇間早期注意の設定値。
///
/// 150mは衝突境界ではなく、桜川で対向する艇を監視者が早めに把握するための
/// 表示ゲートである。既存の衝突警報・音声の閾値には使わない。
const observerAwarenessDisplayDistanceMeters = 150.0;

/// 非表示で対向接近を確認し始める距離。150mへ入った瞬間の確認待ちを減らす。
const observerAwarenessPrearmDistanceMeters = 180.0;

/// 停止・回頭中の保持方位を対向判定へ使わないための最低速度。
const observerAwarenessMinimumSpeedMetersPerSecond = 0.5;

/// 中心線が使えない場合の対向方位差。
const observerAwarenessFallbackOpposingHeadingDegrees = 120.0;

/// 直線距離がこの速度以上で縮まっているときだけ縮退対向とする。
const observerAwarenessMinimumClosingSpeedMetersPerSecond = 0.5;

/// 新規の橙バナーに必要な、異なる受信点を含む最小観測数。
const observerAwarenessMinimumObservations = 3;

const observerAwarenessConfirmDuration = Duration(seconds: 2);
const observerAwarenessClearDuration = Duration(seconds: 3);
const observerAwarenessDataDegradedHoldDuration = Duration(seconds: 5);

/// 既存の他艇外挿上限と合わせる。これを超えた値で新規早期注意を作らない。
const observerAwarenessMaximumTrackAge = Duration(seconds: 6);

/// 現行の逆走案内と同じ確認時間。監視表示だけを即時化しない。
const observerReverseConfirmDuration = Duration(seconds: 6);
