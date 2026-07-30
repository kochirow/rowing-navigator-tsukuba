/// 方位をGoogle Mapsの0〜360度の範囲へ正規化する。
double normalizeBearing(double heading) {
  final safeHeading = heading.isFinite ? heading : 0.0;
  return safeHeading % 360;
}

/// ローイングのナビ画面で、艇の実際の進行方向を画面下へ向けるための
/// カメラ方位を返す。
///
/// Google Mapsではカメラの方位が画面上方向になるため、進行方位を180度
/// 回転させる。自艇マーカーは実際の進行方位を使うので、画面上では下向きになる。
double rowingMapBearing(double travelHeading) {
  final safeHeading = travelHeading.isFinite ? travelHeading : 0.0;
  return (safeHeading + 180) % 360;
}
