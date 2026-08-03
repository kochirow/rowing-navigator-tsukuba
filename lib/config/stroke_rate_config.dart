// =====================================================
// ストロークレート(SPM)計測の設定値
// 端末の加速度センサから艇の前後加速の周期を検出する。
// =====================================================

/// 解析に使う直近の時間窓 [秒]
const spmWindowSec = 15;

/// 加速度の要求サンプリング周期 [ミリ秒](50Hz)。
/// 先行研究の100Hzより低消費電力に保ちつつ、最大65spmでも1周期あたり
/// 約46点を確保する。実際の端末時刻で計算するため、OS側の揺れは補正する。
const spmSamplingMs = 20;

/// 推定対象のレート範囲 [spm]。
const spmMinimumRate = 12.0;
const spmMaximumRate = 65.0;

/// 中央値から、このMAD倍率を超える山・谷だけを候補にする。
const spmExtremumThresholdFactor = 0.8;

/// SPMを算出する最低ストローク数(これ未満なら「計測不能」とする)。
const spmMinimumStrokeCount = 4;

/// 解析開始に必要な最小サンプル数と時間。
const spmMinimumSamples = 80;
const spmMinimumAnalysisSeconds = 3;

/// ドリフト除去・信号平滑化の時定数 [秒]。
const spmDriftTimeConstantSeconds = 0.8;
const spmSmoothingTimeConstantSeconds = 0.06;
const spmMaximumSampleGapSeconds = 0.25;

/// 停止・手持ちノイズを棄却する信号強度 [m/s²]。
const spmMinimumSignalSpread = 0.035;
const spmMinimumSignalEnergy = 0.02;

/// ストローク間隔の外れ値・ばらつき許容。
const spmIntervalOutlierSeconds = 0.12;
const spmIntervalOutlierFraction = 0.18;
const spmMaximumIntervalCoefficientOfVariation = 0.14;
const spmMinimumPeriodicityCorrelation = 0.55;

/// 低信頼な推定値を表示しないためのしきい値。
const spmMinimumConfidence = 0.62;
const spmConfidenceFullIntervals = 5.0;
const spmConfidenceFullSpread = 0.25;

/// SPM表示の更新間隔 [秒]
const spmUpdateIntervalSec = 1;

/// IMUを安全経路の艇速・距離・短時間推測へ接続するロールバックスイッチ。
/// falseでもSPMと実験的な艇速分析は残し、航行推定だけ従来GNSSへ戻す。
const enableInertialNavigationFusion = true;

/// IMU艇速を安全経路のKalman速度観測へ使う最低信頼度。
/// 研究上の改善は固定端末・周期が明瞭な区間で得られているため、低信頼時は
/// 従来のGNSS速度へ即座に戻す。
const imuNavigationMinimumConfidence = 0.68;

/// 安全経路へ使えるIMU解析結果の最大鮮度。
const imuNavigationMaximumAge = Duration(seconds: 2);
