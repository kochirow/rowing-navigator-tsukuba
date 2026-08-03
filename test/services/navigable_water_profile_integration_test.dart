import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/preset_obstacle_service.dart';
import 'package:rowing_navigator/theme/map_layer_spec.dart';

/// 同梱プリセット（`assets/data/sakuragawa_obstacles.json`）の航路レーンが、
/// 地図に往路・復路として描ける状態を保っているかを実データで確かめる。
///
/// `leg` は表示専用の付加フィールドなので、作図ツール
/// （`tool/obstacle-plotter`）から書き出し直すと**黙って消える**。
/// 消えても航路は無彩色で描かれ航行は止まらない（原則1）が、往路・復路の
/// 区別は失われる。ここで落ちれば、その退行に気づける。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('同梱プリセットの全レーンが往路・復路のどちらかを持つ', () async {
    final waters = await PresetObstacleService().loadNavigableWaters();
    final lanes = waters.where((water) => water.kind == 'lane').toList();

    expect(lanes, isNotEmpty, reason: '航路レーンが1本も読めていない');
    for (final lane in lanes) {
      expect(
        lane.leg,
        anyOf('outbound', 'return'),
        reason: '${lane.id} の leg が失われている（作図ツールからの書き出しで消えた可能性）',
      );
    }
  });

  test('往路・復路が両方そろっている', () async {
    final waters = await PresetObstacleService().loadNavigableWaters();
    final legs = waters
        .where((water) => water.kind == 'lane')
        .map((lane) => lane.leg)
        .toSet();

    expect(legs, containsAll(<String>['outbound', 'return']));
  });

  test('leg は direction から導けない（導いてはいけない根拠）', () async {
    // `direction` は「中心線の頂点の並び順に対してどちら向きか」という
    // 安全判定の内部量で、往路・復路という人間の呼び名とは無関係である。
    // 実データでも桜川河口の往路は direction: "against" になっている。
    // この関係が実データで崩れていないことを、ここで固定しておく。
    final waters = await PresetObstacleService().loadNavigableWaters();
    final lanes = await PresetObstacleService().loadChannelLanes();
    final directionById = {for (final lane in lanes) lane.id: lane.direction};

    final outboundDirections = waters
        .where((water) => water.leg == 'outbound')
        .map((water) => directionById[water.id])
        .whereType<Object>()
        .toSet();

    expect(
      outboundDirections.length,
      greaterThan(1),
      reason: '往路の direction が1種類に揃っている。'
          'leg を direction から導ける状態に見えてしまうが、それは偶然である',
    );
  });

  test('実データのレーンに配色を割り当てられる', () async {
    final waters = await PresetObstacleService().loadNavigableWaters();

    for (final water in waters.where((water) => water.kind == 'lane')) {
      for (final isSatellite in [false, true]) {
        final style = laneStyleFor(leg: water.leg, isSatellite: isSatellite);
        // 描ける形になっていること（見えない = 描かないと同じ）。
        expect(style.strokeWidth, greaterThan(0));
        expect(style.strokeColor.a, greaterThan(0));
      }
      // 地図に出すには3点以上必要。
      expect(water.points.length, greaterThanOrEqualTo(3));
    }
  });
}
