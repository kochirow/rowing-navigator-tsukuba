// =====================================================
// ナビゲーション(位置取得・送信)の設定値
// =====================================================

/// リスク評価・記録の周期 [秒](送信周期ではない)
/// 自艇のリスク評価と航行記録はこの周期で必ず行われるため、
/// 送信間隔を伸ばしても静的危険区域への警告には影響しない。
const positionUpdateInterval = 1;

// ---------------- GPS品質・死活監視 ----------------

/// 初回測位を待つ上限時間 [秒]。屋内やGPS無効時の無限待ちを防ぐ。
const initialPositionTimeoutSeconds = 15;

/// この精度[m]を超える測位は低精度として扱う。
/// ロバスト位置推定が有効なら棄却せず、観測重みを下げ、不確実性を
/// 広げたまま警告・記録・位置共有を継続する。
const degradedGpsAccuracyThresholdMeters = 25.0;

/// 前回の正常測位から許容する最大移動速度[m/s]。
/// 競技艇として現実的でない位置飛びを棄却する。
const maxAcceptedGpsSpeedMetersPerSecond = 10.0;

/// 現在時刻からこれより古い測位は使わない。停止したGPSの古いfixを
/// 新しい位置として再採用することを防ぐ。
const maxGpsTimestampAgeSeconds = 10;

/// GNSSのみを使う4状態のロバストKalman推定を有効にする。
/// 追加のセンサー、Timer、通信は使わず、既存の1Hz処理内だけで更新する。
const enableRobustPositionFilter = true;

/// Kalmanの dt に、処理時刻ではなくGNSSの測位時刻を使う。
/// OSのバッファリングとイベントループ遅延によるジッタ(数百ms)が
/// dt誤差と進行方向の位置遅れになるのを防ぐ。
const useGnssTimestampForEstimator = true;

/// GNSS測位時刻と処理時刻の差がこれを超えたら、時計異常とみなして
/// 処理時刻へ退避する [秒]。端末時計の自動補正・逆行への防御。
const maxGnssProcessingClockDriftSeconds = 2.0;

/// Kalman推定位置が生fixからこれ以上離れたら発散とみなして棄却する [m]。
/// 実際の判定では `max(この値, accuracy × 5)` を使う。
const minEstimateDivergenceLimitMeters = 50.0;

// ---------------- 通信バックエンド ----------------

/// true: 位置共有に Realtime Database を使用(推奨・無料枠内で運用可能)
/// false: 従来どおり Firestore を使用(切り戻し用)
const useRealtimeDatabaseForPositions = true;

/// Realtime Database の URL。
/// firebase_options.dart に databaseURL が含まれていない場合はここで指定する。
/// 例: 'https://rowing-navigator-default-rtdb.asia-southeast1.firebasedatabase.app'
/// 空文字の場合は Firebase の既定 URL を使用する。
const realtimeDatabaseUrl = '';

// ---------------- 適応送信 ----------------
// 状況に応じて位置送信の間隔を変え、通信量と電池消費を削減する。
// 受信側は速度・針路から推測航法で補間するため、地図表示は滑らかなまま。
// 停止中の艇は位置が変わらないため、間隔を伸ばしても他艇側の警告精度は落ちない。

/// 実際の接近リスクが検出されたときの送信間隔 [秒]。
/// 端末内の警告・記録は1Hzのまま維持し、クラウド送信だけ2秒にする。
/// 12台が全練習時間この状態でも、RTDB Spark 10GB/月に
/// protocol/暗号化overhead用の十分な余白を残す。
const sendIntervalElevatedRiskSec = 2;

/// 他艇が近いが、まだ接近リスクがないときの送信間隔 [秒]。
/// 受信側は速度・針路で毎秒補間するため、マップと安全判定は
/// 1Hzのまま、通信量と電池消費だけを抑えられる。
const sendIntervalNearOthersSec = 2;

/// 周囲に他艇がいないときの送信間隔 [秒]
const sendIntervalNoOthersNearbySec = 5;

/// 停止中(speed < stoppedSpeedThreshold)の送信間隔 [秒]
/// 注意: boatStaleTimeoutSeconds(risk_evaluator_config.dart)より
/// 十分短くすること。超えると他艇から幽霊艇扱いされて消える。
const sendIntervalStoppedSec = 10;

/// 「停止中」と判定する速度のしきい値 [m/s]
const stoppedSpeedThreshold = 0.5;

/// 「他艇が近い」と判定する半径 [m]
const nearbyBoatRadius = 300.0;

// ---------------- 画面表示 ----------------

/// 最後のGPS測位からこの秒数以上経過したら、
/// ナビ画面に「GPS途絶」インジケータを表示する [秒]
const gpsStaleIndicatorSec = 5;

/// GNSS streamが無通知で止まったとみなし、購読を作り直すまでの時間。
///
/// 2026-07-30実機ログでは15秒の監視により18〜20秒の欠測が複数回残った。
/// GPS品質がunusableになる10秒より前に再購読を始め、カルマン判定経路は
/// そのまま維持する。
const gpsStreamSilenceRecoverySeconds = 8;

/// 1Hz記録を約10時間まで保持する。異常な長時間セッションで
/// メモリが無制限に増え、警告処理を圧迫することを防ぐ。
const maxSessionTrackPoints = 36000;

/// 電池残量APIの再読込間隔 [秒]。
const batteryLevelCacheSeconds = 60;

/// 自艇へ小さな低電池通知を出す残量 [%]。
const lowBatteryWarningPercent = 20;

/// 充電中の20%前後の揺れで通知を繰り返さないための解除残量 [%]。
const lowBatteryWarningResetPercent = 25;

// ---------------- 航行終了 ----------------

/// 航行終了の「開始チェックポイント保存」の上限。
/// これだけは最初に待ち、以降の端末・通信処理が詰まっても練習記録を残す。
const navigationStopCheckpointTimeout = Duration(seconds: 5);

/// 航行終了処理の1工程あたりの既定上限。
const navigationStopStepTimeout = Duration(seconds: 5);

/// 航行終了処理全体の時間予算。超えた工程は実行せず、画面復帰を優先する。
const navigationStopTotalBudget = Duration(seconds: 15);

/// 航行開始前にチーム共有安全設定を最新化する待機上限。
///
/// 同じチームの次回航行では設定を揃えるためサーバー取得を試みるが、圏外や
/// Rules未反映で開始を止めない。失敗時は直前の検証済みキャッシュ、無ければ
/// 端末設定/コード既定値へ縮退し、その出所を計器と診断に明示する。
const sharedSafetyFetchTimeout = Duration(seconds: 3);

// ---------------- 画面常時点灯 ----------------

/// 航行中の常時点灯状態をOS復帰後にも再適用する保険の周期。
/// 漕手は航行中に端末を操作できないため、画面が消えないことを優先する。
const screenWakelockReassertInterval = Duration(seconds: 60);
