enum BoatType {
  r_1x,
  r_2m,
  r_2x,
  r_2p,
  r_4m,
  r_4x,
  r_4p,
  r_8p,
}

// ########################
// 命名規則
// ########################
// {ship_category}_{boat_type}
// ship_category: r(rowing)
// boat_type: 1x, 2m(2-), 2x, 2p(2+), 4m(4-), 4x, 4p(4+), 8p(8+)
// 「-」は m(minus)、「+」は p(plus)。8+ の r_8p に合わせた。

/// 保存されている艇種名(`r_8p` など)を画面用の「8+」「4x」にする。
///
/// 練習記録は艇種を `BoatType.name` の文字列で持つため、そのまま出すと
/// 内部名が画面に漏れる。一覧と記録画面の両方がここを通る。
/// 列挙に無い古い名前は数字から推定し、それも無ければ元の文字列を返す。
String boatTypeDisplayLabel(String storedName) {
  for (final type in BoatType.values) {
    if (type.name == storedName) return type.displayLabel;
  }
  for (final type in BoatType.values) {
    if (type.displayLabel == storedName) return storedName;
  }
  final s = storedName.toLowerCase();
  if (s.contains('8')) return '8+';
  if (s.contains('4')) return '4x';
  if (s.contains('2')) return '2x';
  if (s.contains('1')) return '1x';
  return storedName;
}

/// 送受信した艇種名を [BoatType] にする。列挙に無ければ null。
BoatType? tryParseBoatType(Object? value) {
  if (value is! String) return null;
  for (final type in BoatType.values) {
    if (type.name == value) return type;
  }
  return null;
}

extension BoatTypeDisplay on BoatType {
  /// 画面に出す艇種名。`BoatConfig.label` と同じ表記。
  String get displayLabel => switch (this) {
        BoatType.r_1x => '1x',
        BoatType.r_2m => '2-',
        BoatType.r_2x => '2x',
        BoatType.r_2p => '2+',
        BoatType.r_4m => '4-',
        BoatType.r_4x => '4x',
        BoatType.r_4p => '4+',
        BoatType.r_8p => '8+',
      };

  /// 艇の大きさの区分。当たり判定・停止距離はこの区分の値を使う。
  ///
  /// 漕手の人数が同じなら艇の大きさはほぼ変わらない(利用者の判断、
  /// 2026-10-20)。そのため 2-/2+ は 2x、4-/4+ は 4x の寸法を共有する。
  /// 位置共有の `boatType` にもこの区分を送る。2026-10-20 より前の版は
  /// 知らない艇種名を 1x として扱うので、4+ をそのまま送ると旧版の端末で
  /// 1x の大きさに縮み、警告漏れになる。
  BoatType get sizeClass => switch (this) {
        BoatType.r_1x => BoatType.r_1x,
        BoatType.r_2m || BoatType.r_2x || BoatType.r_2p => BoatType.r_2x,
        BoatType.r_4m || BoatType.r_4x || BoatType.r_4p => BoatType.r_4x,
        BoatType.r_8p => BoatType.r_8p,
      };
}
