import '../../types/home_phase.dart';

// # 地図のメニューの並び
//
// どの姿勢で、何を、どの順・どの見出しで出すかを、ここだけで決める(純Dart)。
// `home_map_screen.dart` の `openMapMenu` は、ここで決まった id から項目を作るだけ。
//
// 決め方(docs/実装計画_2026-10-28_メニュー構成の整理.md):
// - 見出しは「何が入っているか」を名詞で言う。以前の「準備」「この端末」は
//   練習・警告・チームや、設定・状態・読み物が混ざり、名前から中身を当てられなかった。
// - 塊は陸上でよく使う順に並べる(練習 → 警告と危険区域 → チーム → 使い方と情報)。
// - 航行中の6項目の順番は変えない(漕ぎながら覚えた位置を動かさない)。陸上の並びは、
//   航行中の6項目の上下関係を崩さないように組んである。航行中は見出しを出さない。
// - 表示は見出しなしで最上段。艇上で誤って押しても地図の見え方が変わるだけ。

enum MapMenuItemId {
  display,
  practiceRecords,
  workout,
  practiceLog,
  addHazard,
  warningSettings,
  warningVolume,
  calibrateFixedHazards,
  team,
  deviceStatus,
  usageGuide,
  aboutApp,
  developerDetails,
}

class MapMenuSlot {
  final MapMenuItemId id;

  /// 見出し。直前の項目と変わったところにだけ出す。null は見出しなし。
  final String? section;

  const MapMenuSlot(this.id, [this.section]);

  @override
  String toString() => '${section ?? '-'}:${id.name}';
}

const mapMenuSectionPractice = '練習';
const mapMenuSectionWarnings = '警告と危険区域';
const mapMenuSectionTeam = 'チーム';
const mapMenuSectionHelp = '使い方と情報';

List<MapMenuSlot> mapMenuLayout(HomePhase phase,
    {required bool showDeveloper}) {
  final onLand = phase != HomePhase.navigating;
  // 航行中は6項目だけなので見出しを付けない。
  String? s(String name) => onLand ? name : null;
  return [
    const MapMenuSlot(MapMenuItemId.display),
    // 記録・ワークアウトの準備・一括ログは陸上で使う。航行中は艇の上で
    // 過去の記録を読む場面がなく、ワークアウトは地図右のボタンが入口。
    if (onLand) ...[
      MapMenuSlot(MapMenuItemId.practiceRecords, s(mapMenuSectionPractice)),
      MapMenuSlot(MapMenuItemId.workout, s(mapMenuSectionPractice)),
      MapMenuSlot(MapMenuItemId.practiceLog, s(mapMenuSectionPractice)),
    ],
    MapMenuSlot(MapMenuItemId.addHazard, s(mapMenuSectionWarnings)),
    MapMenuSlot(MapMenuItemId.warningSettings, s(mapMenuSectionWarnings)),
    MapMenuSlot(MapMenuItemId.warningVolume, s(mapMenuSectionWarnings)),
    // 位置合わせは出艇前だけ。成功するとチーム全員の警告位置が動くので、
    // 艇を出している最中(航行中・監視中)には出さない。
    if (phase == HomePhase.ashore)
      MapMenuSlot(
          MapMenuItemId.calibrateFixedHazards, s(mapMenuSectionWarnings)),
    if (onLand) MapMenuSlot(MapMenuItemId.team, s(mapMenuSectionTeam)),
    MapMenuSlot(MapMenuItemId.deviceStatus, s(mapMenuSectionHelp)),
    MapMenuSlot(MapMenuItemId.usageGuide, s(mapMenuSectionHelp)),
    // 読み物なので、漕ぎながら開く場面のない航行中には出さない。
    if (onLand) MapMenuSlot(MapMenuItemId.aboutApp, s(mapMenuSectionHelp)),
    if (showDeveloper)
      MapMenuSlot(MapMenuItemId.developerDetails, s(mapMenuSectionHelp)),
  ];
}
