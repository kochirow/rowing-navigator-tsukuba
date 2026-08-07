import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/risk_evaluator_config.dart';
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

  test('実データの中心線を地図の中央線として描ける', () async {
    // 地図に描く中央線は、予測が使う中心線そのものである
    // （別の線を「中央線」として見せると、地図と警告が食い違う）。
    final centerlines = await PresetObstacleService().loadChannelCenterlines();

    expect(centerlines, isNotEmpty, reason: '中心線が1本も読めていない');
    for (final entry in centerlines.entries) {
      // 地図に線として出すには2点以上必要。
      expect(
        entry.value.vertices.length,
        greaterThanOrEqualTo(2),
        reason: '${entry.key} を線として描けない',
      );
    }
    for (final isSatellite in [false, true]) {
      final style = channelDividerStyleFor(isSatellite: isSatellite);
      expect(style.coreWidth, greaterThan(0));
      expect(style.coreColor.a, greaterThan(0));
    }
  });

  test('中心線は、往路レーンと復路レーンの境界になっている', () async {
    // 地図には中央線を1本だけ描き、レーンの外側の辺は描かない。
    // 「中心線 = 2つのレーンの境目」が崩れると、描いた白い破線が
    // 「越えない線」を指さなくなる。
    final service = PresetObstacleService();
    final lanes = await service.loadChannelLanes();
    final centerlines = await service.loadChannelCenterlines();
    final laneCross = <String, List<double>>{};

    for (final lane in lanes) {
      final centerline = centerlines[lane.centerlineId];
      expect(centerline, isNotNull, reason: '${lane.id} の中心線が引けていない');
      laneCross[lane.id] = [
        for (final point in lane.points) centerline!.project(point).crossMeters,
      ];
    }

    // 中心線を共有する2枚は、互いに反対側にある（平均の符号が逆）。
    final byCenterline = <String, List<String>>{};
    for (final lane in lanes) {
      byCenterline.putIfAbsent(lane.centerlineId ?? '', () => []).add(lane.id);
    }
    for (final entry in byCenterline.entries) {
      expect(entry.value.length, 2, reason: '${entry.key} のレーンが2枚ではない');
      final means = entry.value.map((id) {
        final values = laneCross[id]!;
        return values.reduce((a, b) => a + b) / values.length;
      }).toList();
      expect(
        means.first * means.last,
        lessThan(0),
        reason: '${entry.key} の2枚が中心線の同じ側にある',
      );
      for (final mean in means) {
        expect(
          mean.abs(),
          greaterThan(1.0),
          reason: '${entry.key} のレーンが中心線と縮退していて左右を決められない',
        );
      }
    }
  });

  test('霞ヶ浦のレーンは逆走判定を出さない(S3-15)', () async {
    // レーンによる逆走判定は「川幅40〜50m・右側通行の片側1レーンで
    // すれ違う」という桜川本流の運用前提に依存している。
    // 霞ヶ浦は開水面で、この前提が成立しない。
    //
    // 2026-08-06 実機ログ: 全5端末の航跡の 17〜44% がどちらのレーンにも
    // 入っていなかった。片側50m 広げても A 28.8% / B 19.1% / C 22.0% が
    // 外に残り、10% 未満にするには両レーンが重なるまで広げるしかない。
    //
    // 除外は設定値側で持つ(危険区域プロファイルのsha256は firestore.rules が
    // 固定しているため、ルール配備を伴わずに変えられない)。
    // ここではプロファイル側のレーンIDと設定値が対応していることを固定する。
    final lanes = await PresetObstacleService(includeTestZones: false)
        .loadChannelLanes();
    final lake = lanes
        .where((lane) => lane.id.startsWith('lane_kasumikagaura'))
        .toList();
    expect(lake, isNotEmpty, reason: '霞ヶ浦のレーンが見つからない');
    for (final lane in lake) {
      expect(
        reverseGuidanceDisabledLaneIds.contains(lane.id),
        isTrue,
        reason: '${lane.id} は開水面なので逆走判定を出してはいけない',
      );
    }

    // 桜川本流では従来どおり有効であること。
    final river = lanes
        .where((lane) => lane.id.startsWith('lane_sakuragawa'))
        .toList();
    expect(river, isNotEmpty);
    for (final lane in river) {
      expect(
        reverseGuidanceDisabledLaneIds.contains(lane.id),
        isFalse,
        reason: lane.id,
      );
    }

    // 設定値が実在しないレーンIDを指していないこと(綴り誤りの検出)。
    final allIds = lanes.map((lane) => lane.id).toSet();
    for (final id in reverseGuidanceDisabledLaneIds) {
      expect(allIds, contains(id), reason: '$id はプロファイルに存在しない');
    }
  });
}
