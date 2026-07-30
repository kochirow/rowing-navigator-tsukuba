/// 自艇針路から見た相対方位を8方位の日本語ラベルで返す。
/// [myHeading] 自艇の針路 [度]
/// [bearingToTarget] 自艇位置から対象への方位 [度]
String relativeDirectionLabel(double myHeading, double bearingToTarget) =>
    relativeDirectionLabelOf(
        relativeBearingDegrees(myHeading, bearingToTarget));

/// 自艇針路を基準にした相対方位を -180〜180 [度] で返す。
/// 正が右舷側、負が左舷側。
double relativeBearingDegrees(double myHeading, double bearingToTarget) =>
    (bearingToTarget - myHeading + 540) % 360 - 180;

/// 相対方位 [度](-180〜180)を8方位の日本語ラベルにする。
///
/// 漕手は進行方向を見ていないため、「何が」だけでなく「どちらを向くか」を
/// 伝えないと、振り向く side を決めるのに時間を失う。
String relativeDirectionLabelOf(double relative) {
  if (!relative.isFinite) return '';
  final rel = (relative + 540) % 360 - 180;
  final abs = rel.abs();
  if (abs <= 22.5) return '前方';
  if (abs >= 157.5) return '後方';
  if (rel > 0) {
    if (abs < 67.5) return '右前方';
    if (abs <= 112.5) return '右';
    return '右後方';
  } else {
    if (abs < 67.5) return '左前方';
    if (abs <= 112.5) return '左';
    return '左後方';
  }
}
