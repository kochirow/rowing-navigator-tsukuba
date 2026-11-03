import '../config/log_export_config.dart';
import '../models/practice_log_model.dart';
import '../models/session_model.dart';
import 'diagnostic_bundle_service.dart';

/// 練習の後の「今日の記録」シートを出すかどうか(R1-R2・R1-R12)。
///
/// 表示だけを決める純粋な判断。安全経路には何も戻さない。

/// 航行の記録でシートを出すか。
///
/// 未送信で、まだ一度も出していない記録のうち、
/// (a) まとめて送る対象(練習時間15分・2km以上)か、
/// (b) 警告音が1回以上鳴った記録([sessionEndPromptAfterAnyWarningAudio])。
bool shouldPromptSessionEnd(Session session) {
  if (!session.isComplete) return false;
  if (session.isDiagnosticsShared) return false;
  if (session.endPromptShownAt != null) return false;
  if (isBulkLogExportCandidate(session)) return true;
  return sessionEndPromptAfterAnyWarningAudio &&
      warningAudioCountsOf(session).isNotEmpty;
}

/// 監視ログでシートを出すか(まとめて送る対象のときだけ。警告音は数えない)。
bool shouldPromptPracticeLogEnd(PracticeLog log) {
  if (!log.isComplete) return false;
  if (log.endPromptShownAt != null) return false;
  return isBulkPracticeLogTarget(log);
}

/// 鳴らし始めた警告音の回数を、種類ごとに数える。
///
/// `warning_presentation_requested` は音声層への再生の要求で、新しい警告・
/// 鳴り方の変化・逆走注意などの組ごとに1回書かれる。読み上げの繰り返し
/// (ループ)は数えない。再生の要求であって、本人に聞こえたことの証明ではない。
Map<String, int> warningAudioCountsOf(Session session) {
  final counts = <String, int>{};
  for (final event in session.diagnosticEvents) {
    if (event.type != 'warning_presentation_requested') continue;
    final category = event.details['category'];
    if (category is! String || category.isEmpty) continue;
    counts.update(category, (count) => count + 1, ifAbsent: () => 1);
  }
  return counts;
}
