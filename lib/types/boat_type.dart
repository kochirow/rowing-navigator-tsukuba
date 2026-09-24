enum BoatType {
  r_1x,
  r_2x,
  r_4x,
  r_8p,
}

// ########################
// 命名規則
// ########################
// {ship_category}_{boat_type}
// ship_category: r(rowing)
// boat_type: 1x, 2x, 4x, 8p

/// 保存されている艇種名(`r_8p` など)を画面用の「8+」「4x」にする。
///
/// 練習記録は艇種を `BoatType.name` の文字列で持つため、そのまま出すと
/// 内部名が画面に漏れる。一覧と記録画面の両方がここを通る。
/// 列挙に無い古い名前は数字から推定し、それも無ければ元の文字列を返す。
String boatTypeDisplayLabel(String storedName) {
  for (final type in BoatType.values) {
    if (type.name == storedName) return type.displayLabel;
  }
  final s = storedName.toLowerCase();
  if (s.contains('8')) return '8+';
  if (s.contains('4')) return '4x';
  if (s.contains('2')) return '2x';
  if (s.contains('1')) return '1x';
  return storedName;
}

extension BoatTypeDisplay on BoatType {
  /// 画面に出す艇種名。`BoatConfig.label` と同じ表記。
  String get displayLabel => switch (this) {
        BoatType.r_1x => '1x',
        BoatType.r_2x => '2x',
        BoatType.r_4x => '4x',
        BoatType.r_8p => '8+',
      };
}
