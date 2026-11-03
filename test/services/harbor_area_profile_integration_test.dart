import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/preset_obstacle_service.dart';

/// 同梱プリセットから港の中を読む経路が、**座標が1件も入っていない状態でも
/// 成立している**ことを確かめる(桟橋エリアと同じ考え方)。座標はプロットツールで
/// 入れる。入れたあとは、読めた区域が3点以上の形を持つことをここが保証する。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  PresetObstacleService service() => PresetObstacleService(
        includeTestZones: false,
        useLocalDangerZoneSettings: false,
        useLocalFixedObstacleCalibrations: false,
      );

  test('港の中が未プロットでも読み込みは成功し、危険区域を壊さない', () async {
    final areas = await service().loadHarborAreas();
    expect(areas, isA<List<Object?>>());
    final targets = await service().loadCalibrationTargets();
    expect(targets, isNotEmpty, reason: '固定危険区域の基準線が読めていない');
  });

  test('プロット済みの港の中は3点以上の閉じた形を持つ', () async {
    for (final area in await service().loadHarborAreas()) {
      expect(area.id, isNotEmpty);
      expect(area.points.length, greaterThanOrEqualTo(3),
          reason: '${area.id} がポリゴンになっていない');
    }
  });
}
