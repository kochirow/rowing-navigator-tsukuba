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
/// 響く。情報は `BoatListPanel` と `ObserverStatusIcon` に全て出ており、
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

// ---------------- 監視端末への警告通知(バイブ) ----------------
// 2026-10-30 利用者決定: 航行中の艇で漕手に警告の音が鳴ったら(単発・連続音)、
// 監視端末をバイブさせる。表示のみ(band 0)と system fault は通知しない。
// 画面が表示されている間だけ鳴らす(画面OFF時のローカル通知は次の段階)。

/// 監視端末へのバイブ通知の既定。端末内に保存した選択がなければこれを使う。
const observerWarningVibrationDefaultEnabled = true;

/// これより古い受信メッセージの警告状態は使わない。
///
/// 送信間隔は最長10秒(`sendIntervalStoppedSec`)。警告中は2秒間隔で送るので、
/// 10秒届かない警告状態は終わっているか、届いていない。
const observerWarningMaxMessageAge = Duration(seconds: 10);

/// 同じ艇で、音なしがこの時間続いてから次の音ありで再びバイブさせる。
///
/// 逆走・カーブは5秒あけて2回の読み上げを1組として繰り返す
/// (`guidanceRepeatInterval`)。その間の無音で毎回鳴らさないよう、5秒より長くする。
const observerWarningRearmSilence = Duration(seconds: 10);

/// 複数の艇が同時に変わっても、バイブはこの間隔に1回にまとめる。
const observerWarningMinVibrationInterval = Duration(seconds: 2);

/// 連続音(band 2)の警告で、2回目の振動までの間隔。
const observerWarningSecondVibrationDelay = Duration(milliseconds: 600);
