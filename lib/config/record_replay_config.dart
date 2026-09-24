// =====================================================
// 練習記録リプレイ（記録画面）の設定値
//
// **表示専用。** 衝突判定・提示・位置共有では使わない。
// 値と前提の出典: docs/design_notes/2026-09-24_練習記録リプレイ_全面再設計.md
// （§6.3a〜§7.0）。利用者と HTML 試作（tool/prototypes/record_replay/）で確定した。
// =====================================================

import 'log_config.dart';
import 'rowing_pace_config.dart';

// ---------------- 漕行の区分 ----------------

/// 艇が動いているとみなす速度 [m/s]。停止中のGPSノイズを距離に入れない。
const replayMovingSpeedMps = distanceAccumulationMinSpeed;

/// パドル（軽漕）と練習の漕ぎを分ける速度 [m/s]（500m=4:00）。
/// これより遅い間はSR・DPS・/500m の平均に入れない。
double get replayWorkSpeedMps => RowingPaceProfile.minimumWorkSpeedMps;

/// 距離を積算するときの1区間の上限 [秒]。記録の欠けを長い漕行として数えない。
const replayMaxIntegrationStepSec = 10.0;

/// SRが欠けた点を直前の値で埋める上限 [秒]。
/// IMUのSRは数点おきにしか出ないため。漕いでいる間だけ埋める。
const replaySpmCarryForwardSec = 6.0;

// ---------------- 艇速の推定（設計書 §6.5） ----------------

/// GPS位置から艇速を作るときの前後の幅 [秒]。点ごとの距離を足すと
/// ジグザグで距離が伸びるので、前後5秒の「弦」（直線距離）÷時間を使う。
const replayPositionChordHalfWindowSec = 5.0;

/// 弦の時間幅として受け付ける範囲 [秒]。欠けで幅が崩れた点は使わない。
const replayPositionChordMinSpanSec = 6.0;
const replayPositionChordMaxSpanSec = 14.0;

/// GPSが直接測る速度（ドップラー）を使う速度精度の上限 [m/s]。
const replayDopplerMaxAccuracyMps = 1.5;

/// SR×DPS 候補の DPS 基準を作る前後の幅 [秒]と、GPS位置・GPS速度の一致の許容。
const replayDpsReferenceHalfWindowSec = 60.0;
const replayDpsAgreementTolerance = 0.10;
const replayDpsReferenceMinSamples = 3;

/// 全候補をそろえる中心平均の半幅 [秒]（=10秒平均）。
/// GPS速度はストローク内の本物の速度の波を含むので、時間の細かさをそろえてから比べる。
const replayCandidateHalfWindowSec = 5.0;

/// 候補の採否。一番ずれの小さい候補の1.6倍（最低2%）以内を採用する。
/// 固定の閾値は、候補全体の質が低い記録で良い候補まで外したため使わない。
const replayCandidateAdoptRatio = 1.6;
const replayCandidateAdoptFloor = 0.02;

/// 候補のずれを測るのに必要な点数。これより少ない候補は採否を決められない。
const replayCandidateMinCompareSamples = 60;

/// 艇種別の2000m世界最高（男子）[秒]。これより速い艇速はありえないものとして切る。
/// 出典: World Rowing の world best times。1x 6:30.74 / 2x 5:59.72 / 4x 5:32.03 / 8+ 5:17.75。
const replayWorldBest2000mSec = <String, double>{
  '1x': 390.74,
  '2x': 359.72,
  '4x': 332.03,
  '8+': 317.75,
};
const replayWorldBestMargin = 1.02;

/// 艇の平均速度が1秒で変えられる量の上限 [m/s²]。
/// スタートの加速（0→5m/s を約15秒）は通し、2秒で2m/s変わるような跳びは通さない。
const replayMaxAccelerationMps2 = 0.3;

/// 推定の最後にかける中心平均の半幅 [秒]。振り返りなので遅れの出ない中心窓にする。
const replayOutputHalfWindowSec = 5.0;

// ---------------- セットの判定（設計書 §7.0） ----------------

/// SRのならし（前後の中央値）の半幅 [秒]。動いている点の、この範囲のSRだけを使う。
/// 陸上で艇を運ぶ揺れでSR60前後が記録されるため、範囲外のSRは捨てる。
const replaySpmSmoothingHalfWindowSec = 4.0;
const replayValidSpmMin = 10.0;
const replayValidSpmMax = 50.0;

/// 強度の区分（British Rowing の UT2 18-22 / UT1 22-26 / AT 26-28 / TR・AN 32-40 を参考に、
/// 部の言い方「UTはSR16〜24、ハイレートはSR28以上」に合わせた）。
const replaySteadyUtMaxSpm = 24.0;
const replayHighRateSpm = 28.0;

/// ハイレートの本の立ち上がり（直前のSR25以上・6秒以内）は本に含める。
const replayHighRateLeadSpm = 25.0;
const replayHighRateLeadSec = 6.0;

/// ハイレートの本の最小の長さと、途切れの許容。
const replayHighRateMinDurationSec = 15.0;
const replayHighRateMinDistanceMeters = 60.0;
const replayHighRateMaxGapSec = 6.0;

/// ハイレートの本をひとつのセットにまとめる間隔の上限 [秒]。2026-09-24 利用者判断で5分。
const replayHighRateSetMaxRestSec = 300.0;

/// UT/AT の区間を探すときに、インターバルのセットの前後を除く余白 [秒]。
const replayHighRateMaskMarginSec = 5.0;

/// UT/AT の区間（既存のピース判定を使う）の連結と足切り。
const replaySteadyMergeGapSec = 25.0;
const replaySteadyMinDurationSec = 60.0;
const replaySteadyMinDistanceMeters = 250.0;

/// UT/AT の区間をひとつのセットにまとめる停止の上限 [秒]。ターン・停止をはさむ。
const replaySteadySetMaxGapSec = 240.0;

/// 本と本のすき間の呼び方。向きが120°以上変わった=ターン、6割以上止まっていた=停止。
const replayTurnHeadingChangeDeg = 120.0;
const replayStoppedFraction = 0.6;

// ---------------- グラフ（設計書 §6.3a/§6.3b） ----------------

/// 縦軸の範囲を決める点から除く、本の最初と最後の秒数（加速・減速）。
const replayChartCoreTrimSec = 8.0;

/// /500m の縦軸: 上端=速い側2%、下端=そこから最大40秒（かつ遅い側10%まで）。
const replayChartPaceFastQuantile = 0.02;
const replayChartPaceSlowQuantile = 0.90;
const replayChartPaceMaxSpanSec = 40.0;

/// SR・DPS の縦軸は 5〜95 パーセンタイル。
const replayChartOtherLowQuantile = 0.05;
const replayChartOtherHighQuantile = 0.95;
