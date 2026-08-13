import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/preset_obstacle_service.dart';

/// 同梱プリセット（`assets/data/sakuragawa_obstacles.json`）から桟橋エリアを
/// 読む経路が、**座標が1件も入っていない状態でも成立している**ことを確かめる。
///
/// 桟橋エリアの座標はプロットツールで入れる。座標が入る前から
/// 「読み込み → 抑制ポリシー → 地図描画」の全経路が動いていなければ、
/// 「データが来たら動くはず」を作ることになる。
///
/// 座標を入れたあとは、`mooringAreas` が実際に読めることをここが保証する。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('桟橋エリアが未プロットでも読み込みは成功し、危険区域を壊さない', () async {
    // 端末内設定へ触らない構成。テスト環境に SharedPreferences は無い。
    final service = PresetObstacleService(
      includeTestZones: false,
      useLocalDangerZoneSettings: false,
      useLocalFixedObstacleCalibrations: false,
    );
    final areas = await service.loadMooringAreas();

    // 未プロットなら空。例外にしない(原則1: 機能を止めない)。
    expect(areas, isA<List<Object?>>());

    // 桟橋エリアの有無に関係なく、固定危険区域の基準線は従来どおり読める。
    final targets = await service.loadCalibrationTargets();
    expect(targets, isNotEmpty, reason: '固定危険区域の基準線が読めていない');
  });

  test('プロット済みの桟橋エリアは3点以上の閉じた形を持つ', () async {
    final areas = await PresetObstacleService(
      includeTestZones: false,
      useLocalDangerZoneSettings: false,
      useLocalFixedObstacleCalibrations: false,
    ).loadMooringAreas();
    for (final area in areas) {
      expect(area.id, isNotEmpty);
      expect(
        area.points.length,
        greaterThanOrEqualTo(3),
        reason: '${area.id} がポリゴンになっていない',
      );
    }
  });
}
