/// 記録画面の数値の書き方。
library;

/// 秒を「m:ss」または「h:mm:ss」にする。
String fmtDuration(double? seconds) {
  if (seconds == null || !seconds.isFinite) return '--';
  final n = seconds.round();
  final sign = n < 0 ? '-' : '';
  final a = n.abs();
  final h = a ~/ 3600, m = (a % 3600) ~/ 60, s = a % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$sign$h:${m.toString().padLeft(2, '0')}:$ss' : '$sign$m:$ss';
}

/// /500m の値（秒）を「m:ss」にする。
String fmtPace(double? secPer500) =>
    secPer500 == null || secPer500 <= 0 ? '--' : fmtDuration(secPer500);

/// 距離を「950m」「7.15km」にする。
String fmtDistance(double meters) => meters >= 1000
    ? '${(meters / 1000).toStringAsFixed(2)}km'
    : '${meters.round()}m';

/// 時計の時刻「06:16:47」。
String fmtClock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:'
    '${t.minute.toString().padLeft(2, '0')}:'
    '${t.second.toString().padLeft(2, '0')}';
