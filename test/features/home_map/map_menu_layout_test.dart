import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/features/home_map/map_menu_layout.dart';
import 'package:rowing_navigator/types/home_phase.dart';

void main() {
  List<MapMenuItemId> ids(HomePhase p, {bool dev = false}) =>
      [for (final s in mapMenuLayout(p, showDeveloper: dev)) s.id];

  List<String> sections(HomePhase p) => [
        for (final s in mapMenuLayout(p, showDeveloper: true))
          if (s.section != null) s.section!
      ].fold<List<String>>(
          [], (a, s) => a.isEmpty || a.last != s ? [...a, s] : a);

  test('陸上は表示を見出しなしで最上段に置き、塊は練習→警告と危険区域→チーム→使い方と情報', () {
    final layout = mapMenuLayout(HomePhase.ashore, showDeveloper: false);
    expect(layout.first.id, MapMenuItemId.display);
    expect(layout.first.section, isNull);
    expect(sections(HomePhase.ashore), [
      mapMenuSectionPractice,
      mapMenuSectionWarnings,
      mapMenuSectionTeam,
      mapMenuSectionHelp,
    ]);
    expect(ids(HomePhase.ashore), [
      MapMenuItemId.display,
      MapMenuItemId.practiceRecords,
      MapMenuItemId.workout,
      MapMenuItemId.practiceLog,
      MapMenuItemId.addHazard,
      MapMenuItemId.warningSettings,
      MapMenuItemId.warningVolume,
      MapMenuItemId.calibrateFixedHazards,
      MapMenuItemId.team,
      MapMenuItemId.deviceStatus,
      MapMenuItemId.usageGuide,
      MapMenuItemId.aboutApp,
    ]);
  });

  test('航行中は6項目で見出しなし、順番は以前と同じ', () {
    final layout = mapMenuLayout(HomePhase.navigating, showDeveloper: false);
    expect(layout.every((s) => s.section == null), isTrue);
    expect(ids(HomePhase.navigating), [
      MapMenuItemId.display,
      MapMenuItemId.addHazard,
      MapMenuItemId.warningSettings,
      MapMenuItemId.warningVolume,
      MapMenuItemId.deviceStatus,
      MapMenuItemId.usageGuide,
    ]);
  });

  test('監視中は位置の調整を出さず、ほかは陸上と同じ', () {
    expect(ids(HomePhase.watching),
        ids(HomePhase.ashore)..remove(MapMenuItemId.calibrateFixedHazards));
  });

  test('どの姿勢でも、共通に出る項目の上下関係は同じ', () {
    final ashore = ids(HomePhase.ashore, dev: true);
    for (final p in HomePhase.values) {
      final other = ids(p, dev: true);
      final common = ashore.where(other.contains).toList();
      expect(other.where(ashore.contains).toList(), common, reason: p.name);
    }
  });

  test('詳細(開発用)は開発ビルドだけ、最後に出る', () {
    for (final p in HomePhase.values) {
      expect(ids(p), isNot(contains(MapMenuItemId.developerDetails)));
      expect(ids(p, dev: true).last, MapMenuItemId.developerDetails);
    }
  });

  test('1つの塊は4項目以下(目で探せる大きさ)', () {
    final counts = <String, int>{};
    for (final s in mapMenuLayout(HomePhase.ashore, showDeveloper: true)) {
      if (s.section != null) counts[s.section!] = (counts[s.section!] ?? 0) + 1;
    }
    expect(counts.values.every((n) => n <= 4), isTrue, reason: '$counts');
  });
}
