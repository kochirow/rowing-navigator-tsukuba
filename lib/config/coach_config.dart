// =====================================================
// コーチダッシュボード(監視)の設定値
// =====================================================

/// この秒数以上動いていない艇を「停止」として通知する [秒]
const stoppedAlertSec = 180;

/// 「停止」判定の速度しきい値 [m/s]
const stoppedSpeedForAlert = 0.5;

/// この秒数以上、艇自身のserverUpdatedAt/timestampが進まない場合に
/// 「更新途絶」として通知する [秒]。
/// (電池切れ・アプリ異常終了・圏外の可能性)
///
/// 45秒では、停止中送信10秒(`sendIntervalStoppedSec`)+ 画面OFF + 通信ジッタで
/// 日常的に成立し、実機テストで「細かいエラーを大きく伝えすぎ」という指摘に
/// つながった。一覧には常に「N秒前」が出ているので情報は失われない。
/// 異常として立てるのは、本当に電池切れ・アプリ終了・圏外を疑う長さにする。
const lostAlertSec = 90;

/// 航跡を表示する時間の長さ [秒]
const trailDurationSec = 600;

/// 異常検知のスキャン間隔 [秒]
const anomalyScanIntervalSec = 5;

/// 同じ異常を再度読み上げるまでの間隔 [秒]。
/// [coachAudibleAnomalyKindNames] が空(既定)のときは音を鳴らさないので使わない。
const anomalyReannounceSec = 120;

/// 監視(コーチ)モードで異常を「音でも」知らせる種類。
///
/// 既定は空 = 無音。監視者は画面を見られる位置にいる
/// (DESIGN_PRINCIPLES 1.3「コーチ艇はいない」・1.4「監視者は陸上にいる」)。
/// 実運用ではトランシーバーアプリ(Buddycom)の音声と干渉し、艇庫周辺の近隣にも
/// 響く。情報は `BoatListPanel` と `CoachAnomalyChip` に全て出ており、
/// 音は情報を足していない。
///
/// トレードオフ: 監視者が画面から目を離している間、沈・電池切れへの気づきが
/// 遅れる。「沈の兆候(長時間停止)だけは音で拾いたい」という運用へ
/// 切り替えられるよう、種類ごとに指定できる形にしてある。
/// 例: `{'stopped'}`(= `BoatAnomalyKind.stopped`)。
///
/// **enum ではなく名前(String)で持つ理由**: `BoatAnomalyKind` は
/// `lib/hooks/use_coach_watch.dart` にある。config から hooks を import すると
/// レイヤー(Presentation → Hooks → Services → API → Models)を逆流し、
/// 設定値を1つ読むだけで Flutter/hooks 一式を巻き込むうえ、
/// `use_coach_watch.dart` がこの config を import しているため循環になる。
/// ここは名前で持ち、突き合わせは `isAudibleCoachAnomalyKind()` が行う。
/// 綴り誤りは `test/hooks/use_coach_watch_test.dart` が検出する。
const coachAudibleAnomalyKindNames = <String>{};
