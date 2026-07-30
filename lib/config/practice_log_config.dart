// =====================================================
// 監視端末による練習一括ログの設定値
// =====================================================

/// 監視者自身の最新測位を記録する間隔。停止中もage_sec付きで書くため、
/// 「岸で監視していた」と「記録が止まった」を区別できる。
const observerTrackIntervalSec = 10;

/// JSONLをまとめて追記する間隔。1点ごとのI/Oが監視表示を遅らせないため。
const practiceLogFlushIntervalSec = 10;

/// 強制終了時にも読めるmeta.jsonへ進捗を反映する間隔。
const practiceLogCheckpointIntervalSec = 60;

/// 2時間・12艇の通常上限より余裕を持つ端末内記録点の上限。到達時は記録だけを
/// 停止し、監視表示・安全経路には一切影響させない。
const maxPracticeLogPoints = 50000;

/// 端末へ保持する完了・未完了一括ログの件数上限。
const maxStoredPracticeLogs = 20;
