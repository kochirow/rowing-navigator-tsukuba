/// 警告の種類の、人が読む短い名前(記録画面・「今日の記録」シートで共通)。
String alertCategoryLabel(String category) => switch (category) {
      'shore' => '岸',
      'bridge' => '橋',
      'bridgePier' => '橋脚',
      'island' => '中州',
      'driftwood' => '流木',
      'pile' => '杭',
      'curve' => 'カーブ',
      'reverse' => '逆走注意',
      'other_boat' => '他艇',
      'other_boat_track_lost' => '他艇情報途絶',
      'gps_unavailable' => 'GPS利用不可',
      'generic' => '危険区域',
      'testZone' => 'テスト区域',
      _ => category,
    };
