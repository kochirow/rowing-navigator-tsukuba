/// 艇種ごとの、記録画面で「漕いでいる」と扱うペース基準。
///
/// セッションには `BoatType.name`（例: r_1x）を保存しているが、過去の
/// 記録やテストでは表示名（例: 1x）もあるため、両方を受け付ける。
class RowingPaceProfile {
  /// ペース推移・自動ピース検出に表示/採用する最も遅いペース [秒/500m]。
  final double displayPaceLimitSecPer500;

  const RowingPaceProfile(this.displayPaceLimitSecPer500);

  /// 500mを4分より速く進んだ時間をワーク時間とする。
  static const workPaceLimitSecPer500 = 240.0;

  static const single = RowingPaceProfile(225); // 3:45 /500m
  static const doubleScull = RowingPaceProfile(195); // 3:15 /500m
  static const quad = RowingPaceProfile(180); // 3:00 /500m
  static const eight = RowingPaceProfile(165); // 2:45 /500m

  double get minimumDisplaySpeedMps => 500 / displayPaceLimitSecPer500;
  static double get minimumWorkSpeedMps => 500 / workPaceLimitSecPer500;

  static RowingPaceProfile forBoatTypeName(String boatTypeName) {
    final normalized = boatTypeName.toLowerCase().replaceAll(' ', '');
    if (normalized.contains('8')) return eight;
    if (normalized.contains('4')) return quad;
    if (normalized.contains('2')) return doubleScull;
    // 未設定の旧記録も、もっとも低い表示基準の1xとして安全に扱う。
    return single;
  }
}
