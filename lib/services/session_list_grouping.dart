import '../models/session_model.dart';

/// 記録一覧の並べ方(純Dart・表示専用)。記録そのものは変えない。

/// 「短い記録」: 1分未満 か 100m 未満。一覧の下にまとめて畳む(消さない)。
/// 航行の開始・終了の押し間違いや、陸上での確認で残った記録が一覧の上を
/// 埋めないようにする。
bool isShortSession(Session s) =>
    s.summary.durationSec < 60 || s.summary.totalDistanceMeters < 100;

/// 直近 [weeks] 週(月曜始まり)ごとの距離 [m]。末尾が今週。
List<double> weeklyDistances(
  List<Session> sessions, {
  required DateTime now,
  int weeks = 8,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final thisMonday = today.subtract(Duration(days: today.weekday - 1));
  final firstMonday = thisMonday.subtract(Duration(days: 7 * (weeks - 1)));
  final totals = List<double>.filled(weeks, 0);
  for (final s in sessions) {
    final d = s.startedAt.toLocal();
    final day = DateTime(d.year, d.month, d.day);
    if (day.isBefore(firstMonday)) continue;
    final index = day.difference(firstMonday).inDays ~/ 7;
    if (index < 0 || index >= weeks) continue;
    final m = s.summary.totalDistanceMeters;
    if (m.isFinite && m > 0) totals[index] += m;
  }
  return totals;
}

/// 直近 [weeks] 週の各週の月曜日。末尾が今週。
List<DateTime> weekStarts(DateTime now, {int weeks = 8}) {
  final today = DateTime(now.year, now.month, now.day);
  final thisMonday = today.subtract(Duration(days: today.weekday - 1));
  return [
    for (var i = weeks - 1; i >= 0; i--)
      thisMonday.subtract(Duration(days: 7 * i)),
  ];
}
