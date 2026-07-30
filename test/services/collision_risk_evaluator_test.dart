import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/config/risk_evaluator_config.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import 'package:rowing_navigator/models/static_obstacle_model.dart';
import 'package:rowing_navigator/services/collision_risk_evaluator_service.dart';
import 'package:rowing_navigator/types/boat_type.dart';
import 'package:rowing_navigator/types/collision_risk_level.dart';
import 'package:rowing_navigator/utils/geo_math.dart';

Boat makeBoat({
  String boatId = 'test',
  double lat = 36.0670,
  double lng = 140.2045,
  double heading = 0.0,
  double speed = 0.0,
  BoatType type = BoatType.r_1x,
  double? accuracy,
}) {
  return Boat(
    boatId: boatId,
    boatType: type,
    lat: lat,
    lng: lng,
    heading: heading,
    speed: speed,
    timestamp: DateTime.now(),
    accuracy: accuracy,
  );
}

// 中心点から半径サイズ[m]の正方形の危険区域を作る
StaticObstacle makeSquareObstacle(LatLng center, double halfSizeMeters) {
  return StaticObstacle(
    id: 'obstacle',
    name: 'テスト区域',
    points: [
      computeOffset(
          computeOffset(center, halfSizeMeters, 0), halfSizeMeters, 90),
      computeOffset(
          computeOffset(center, halfSizeMeters, 0), halfSizeMeters, 270),
      computeOffset(
          computeOffset(center, halfSizeMeters, 180), halfSizeMeters, 270),
      computeOffset(
          computeOffset(center, halfSizeMeters, 180), halfSizeMeters, 90),
    ],
  );
}

void main() {
  final evaluator = CollisionRiskEvaluatorService();

  group('getStoppingDistance', () {
    test('速度が上がると停止距離も長くなる', () {
      final slow = evaluator.getStoppingDistance(makeBoat(speed: 1.0));
      final fast = evaluator.getStoppingDistance(makeBoat(speed: 4.0));
      expect(fast, greaterThan(slow));
    });

    test('停止中の艇の停止距離は0', () {
      expect(evaluator.getStoppingDistance(makeBoat(speed: 0.0)), 0.0);
    });

    test('速度がNaNでも例外にならず停止扱い', () {
      expect(evaluator.getStoppingDistance(makeBoat(speed: double.nan)), 0.0);
    });
  });

  group('evaluateFutureRisk (静的危険区域)', () {
    test('周囲に何もなければ lv0', () {
      final level = evaluator.evaluateFutureRisk(makeBoat(speed: 3.0), [], []);
      expect(level, CollisionRiskLevel.lv0);
    });

    test('進行方向の停止距離内に危険区域があれば lv3', () {
      final myBoat = makeBoat(speed: 3.0, heading: 0.0); // 北へ3m/s
      // 20m前方に20m四方の危険区域(1xの停止距離は約21m)
      final obstacleCenter =
          computeOffset(LatLng(myBoat.lat, myBoat.lng), 30, 0.0);
      final obstacle = makeSquareObstacle(obstacleCenter, 10);
      final level = evaluator.evaluateFutureRisk(myBoat, [], [obstacle]);
      expect(level, CollisionRiskLevel.lv3);
    });

    test('停止中でも kind 別の近接距離内なら lv1 以上', () {
      // 近接注意距離は一律15mではなく区域の種類ごとに決める。
      // 中心線予測が「岸へ向かっている」ケースを検知するようになったため、
      // 近接判定に残る仕事は漂流・方位不明・幾何例外の予備だけになった。
      CollisionRiskLevel levelFor({
        required StaticObstacleKind kind,
        required double edgeDistance,
      }) {
        final myBoat = makeBoat(speed: 0.0, heading: 0.0);
        final obstacleCenter = computeOffset(
          LatLng(myBoat.lat, myBoat.lng),
          edgeDistance + 10,
          90.0,
        );
        final square = makeSquareObstacle(obstacleCenter, 10);
        return evaluator.evaluateFutureRisk(
          myBoat,
          [],
          [
            StaticObstacle(
              id: 'zone',
              points: square.points,
              kind: kind,
            )
          ],
        );
      }

      // 岸は3m。常に近くを走るため最小にしている。
      expect(
        levelFor(kind: StaticObstacleKind.shore, edgeDistance: 2).index,
        greaterThanOrEqualTo(CollisionRiskLevel.lv1.index),
      );
      // 流木は6m。水面下で見えず帰結が最悪なので広く取る。
      expect(
        levelFor(kind: StaticObstacleKind.driftwood, edgeDistance: 5).index,
        greaterThanOrEqualTo(CollisionRiskLevel.lv1.index),
      );
      // 岸から10m離れていれば、停止中に警告しない(過剰警告を避ける)。
      expect(
        levelFor(kind: StaticObstacleKind.shore, edgeDistance: 10),
        CollisionRiskLevel.lv0,
      );
    });

    test('十分離れた危険区域(100m)では lv0', () {
      final myBoat = makeBoat(speed: 0.0);
      final obstacleCenter =
          computeOffset(LatLng(myBoat.lat, myBoat.lng), 110, 90.0);
      final obstacle = makeSquareObstacle(obstacleCenter, 10);
      final level = evaluator.evaluateFutureRisk(myBoat, [], [obstacle]);
      expect(level, CollisionRiskLevel.lv0);
    });

    test('推測余裕秒数の設定で先読み範囲が変わる', () {
      final myBoat = makeBoat(speed: 3.0, heading: 0.0);
      final obstacleCenter =
          computeOffset(LatLng(myBoat.lat, myBoat.lng), 45, 0.0);
      final obstacle = makeSquareObstacle(obstacleCenter, 5);

      // 設定できる下限(`minWarningTimeSeconds`)では 45m 先を検知しない。
      // 下限より小さい値は `_validatedWarningTime` が clamp するため、
      // ここへ直接 5.0 のような値を書くと「5秒で試したつもりが下限で
      // 走っている」状態になり、テストの意味が失われる。
      expect(
        evaluator.evaluateFutureRisk(
          myBoat,
          [],
          [obstacle],
          warningTimeSeconds: minWarningTimeSeconds,
        ),
        CollisionRiskLevel.lv0,
      );
      // clamp されるので、下限未満を渡しても結果は下限と同じになる。
      expect(
        evaluator.evaluateFutureRisk(
          myBoat,
          [],
          [obstacle],
          warningTimeSeconds: 1.0,
        ),
        CollisionRiskLevel.lv0,
      );
      expect(
        evaluator
            .evaluateFutureRisk(
              myBoat,
              [],
              [obstacle],
              warningTimeSeconds: 15.0,
            )
            .index,
        greaterThanOrEqualTo(CollisionRiskLevel.lv2.index),
      );

      final fartherObstacleCenter =
          computeOffset(LatLng(myBoat.lat, myBoat.lng), 70, 0.0);
      final fartherObstacle = makeSquareObstacle(fartherObstacleCenter, 5);
      expect(
        evaluator
            .evaluateFutureRisk(
              myBoat,
              [],
              [fartherObstacle],
              warningTimeSeconds: 25.0,
            )
            .index,
        greaterThanOrEqualTo(CollisionRiskLevel.lv2.index),
      );
    });

    test('同梱プリセットにも近接注意とGPS帯を適用する(特例を持たない)', () {
      // 以前は isDefault かつ proximityCautionDistanceMeters==0 の区域だけ
      // 近接注意とGPS帯を丸ごと無効化する特例があり、桜川の実データでは
      // 全310枚がその条件に当たって両方が効いていなかった。特例は撤去した。
      final myBoat = makeBoat(speed: 0.0, heading: 0.0);
      final obstacleCenter =
          computeOffset(LatLng(myBoat.lat, myBoat.lng), 12, 90.0);
      final square = makeSquareObstacle(obstacleCenter, 10);
      final presetShore = StaticObstacle(
        id: 'preset-shore',
        points: square.points,
        isDefault: true,
        kind: StaticObstacleKind.shore,
      );

      // 縁まで2m。岸の既定3m以内なので注意が出る。
      expect(
        evaluator.evaluateFutureRisk(myBoat, [], [presetShore]).index,
        greaterThanOrEqualTo(CollisionRiskLevel.lv1.index),
      );
      // GPS帯も同梱プリセットへ一様に適用される。
      expect(
        evaluator.staticGpsInflatePerSideMeters(myBoat, presetShore),
        greaterThan(0),
      );
    });

    test('テスト区域は通常の危険区域として将来衝突を判定する', () {
      final myBoat = makeBoat(speed: 3.0, heading: 0.0);
      final obstacleCenter =
          computeOffset(LatLng(myBoat.lat, myBoat.lng), 30, 0.0);
      final obstacle = StaticObstacle(
        id: 'test-zone',
        kind: StaticObstacleKind.testZone,
        points: makeSquareObstacle(obstacleCenter, 10).points,
      );
      expect(
        evaluator.evaluateFutureRisk(myBoat, [], [obstacle]),
        CollisionRiskLevel.lv3,
      );
    });

    test('橋も橋脚と同じく停止距離内では緊急にする', () {
      final myBoat = makeBoat(speed: 3.0, heading: 0.0);
      final bridgeCenter =
          computeOffset(LatLng(myBoat.lat, myBoat.lng), 20, 0.0);
      final bridge = StaticObstacle(
        id: 'bridge',
        kind: StaticObstacleKind.bridge,
        points: makeSquareObstacle(bridgeCenter, 10).points,
      );

      expect(
        evaluator.evaluateFutureRisk(myBoat, [], [bridge]),
        CollisionRiskLevel.lv3,
      );
    });

    test('危険区域名と個別音声を警告表示・再生側へ引き渡す', () {
      final myBoat = makeBoat(speed: 3.0, heading: 0.0);
      final obstacleCenter =
          computeOffset(LatLng(myBoat.lat, myBoat.lng), 20, 0.0);
      final obstacle = StaticObstacle(
        id: 'custom-bridge',
        name: '艇庫前の橋',
        kind: StaticObstacleKind.bridge,
        warningAudioAsset: 'audio/custom_bridge_warning.mp3',
        points: makeSquareObstacle(obstacleCenter, 10).points,
      );

      final assessment = evaluator.assessRisk(myBoat, [], [obstacle]);
      expect(assessment.primaryThreat?.obstacleName, '艇庫前の橋');
      expect(assessment.primaryThreat?.warningAudioAsset,
          'audio/custom_bridge_warning.mp3');
      // 区域の重心(20m先)ではなく、最寄りの辺までの距離を返す。
      // 岸の危険区域は基準線の各辺を長方形にしたものなので、重心距離は
      // 「岸にどれだけ近いか」とほぼ無関係になる。
      expect(
        assessment.primaryThreat?.distanceMeters,
        inInclusiveRange(9, 11),
      );
    });

    test('危険区域の内部では距離が負になり、進入の深さが分かる', () {
      // 自艇を区域の中心に置く。境界までは10m。
      final myBoat = makeBoat(speed: 0.2, heading: 0.0);
      final obstacle = StaticObstacle(
        id: 'inside-zone',
        kind: StaticObstacleKind.shore,
        points: makeSquareObstacle(LatLng(myBoat.lat, myBoat.lng), 10).points,
      );

      final assessment = evaluator.assessRisk(myBoat, [], [obstacle]);
      final distance = assessment.primaryThreat?.distanceMeters;
      expect(distance, isNotNull);
      // 0へ張り付かず、最寄りの辺までの距離が負値で残る。
      expect(distance, lessThan(0));
      expect(distance, inInclusiveRange(-11, -9));
    });

    test('橋と他艇が同時に危険なら他艇の緊急を優先する', () {
      final myBoat = makeBoat(speed: 3.0, heading: 0.0);
      final bridgeCenter =
          computeOffset(LatLng(myBoat.lat, myBoat.lng), 20, 0.0);
      final bridge = StaticObstacle(
        id: 'bridge',
        kind: StaticObstacleKind.bridge,
        points: makeSquareObstacle(bridgeCenter, 10).points,
      );
      final otherBoat = makeBoat(
        boatId: 'other',
        lat: myBoat.lat,
        lng: myBoat.lng,
        heading: 180.0,
        speed: 3.0,
      );

      expect(
        evaluator.evaluateFutureRisk(myBoat, [otherBoat], [bridge]),
        CollisionRiskLevel.lv3,
      );
    });

    test('カーブ区域は区域外の将来予測では警告しない', () {
      final myBoat = makeBoat(speed: 3.0, heading: 0.0);
      final obstacleCenter =
          computeOffset(LatLng(myBoat.lat, myBoat.lng), 30, 0.0);
      final obstacle = StaticObstacle(
        id: 'curve',
        kind: StaticObstacleKind.curve,
        points: makeSquareObstacle(obstacleCenter, 10).points,
      );
      expect(evaluator.evaluateFutureRisk(myBoat, [], [obstacle]),
          CollisionRiskLevel.lv0);
    });

    test('逆走注意区域に現在位置が入ると注意する', () {
      final myBoat = makeBoat(speed: 0.0);
      final obstacle = StaticObstacle(
        id: 'reverse',
        kind: StaticObstacleKind.reverse,
        points: makeSquareObstacle(LatLng(myBoat.lat, myBoat.lng), 10).points,
      );
      final assessment = evaluator.assessRisk(myBoat, [], [obstacle]);
      expect(assessment.level, CollisionRiskLevel.lv1);
      expect(
          assessment.primaryThreat?.obstacleKind, StaticObstacleKind.reverse);
    });

    test('警告対象外にした固定対象物は全ての警告判定から除外する', () {
      final myBoat = makeBoat(speed: 3.0, heading: 0.0);
      final obstacleCenter =
          computeOffset(LatLng(myBoat.lat, myBoat.lng), 20, 0.0);
      final disabled = StaticObstacle(
        id: 'island-upstream',
        kind: StaticObstacleKind.island,
        isWarningEnabled: false,
        points: makeSquareObstacle(obstacleCenter, 10).points,
      );

      expect(
        evaluator.assessRisk(myBoat, [], [disabled]).level,
        CollisionRiskLevel.lv0,
      );
      expect(
        evaluator.findCollisionThreat(myBoat, [], [disabled]),
        isNull,
      );
      expect(evaluator.findProximityThreats(myBoat, [disabled]), isEmpty);
    });
  });

  group('evaluateFutureRisk (他艇)', () {
    test('正面から接近する他艇で lv1 以上', () {
      final myBoat = makeBoat(speed: 3.0, heading: 0.0); // 北へ
      final otherPos = computeOffset(LatLng(myBoat.lat, myBoat.lng), 40, 0.0);
      final otherBoat = makeBoat(
        boatId: 'other',
        lat: otherPos.latitude,
        lng: otherPos.longitude,
        heading: 180.0, // 南へ(正面衝突コース)
        speed: 3.0,
      );
      final assessment = evaluator.assessRisk(myBoat, [otherBoat], []);
      expect(assessment.level.index,
          greaterThanOrEqualTo(CollisionRiskLevel.lv1.index));
      expect(
        assessment.primaryThreat?.distanceMeters,
        inInclusiveRange(39, 41),
      );
    });
  });

  group('他艇の現在位置外挿', () {
    test('送信端末の時計ずれではなくserverUpdatedAtを基準にする', () {
      final now = DateTime.utc(2026, 7, 22, 12);
      final observed = now.subtract(const Duration(seconds: 10));
      final serverUpdated = now.subtract(const Duration(seconds: 2));
      final boat = Boat(
        boatId: 'clock-skewed',
        boatType: BoatType.r_1x,
        lat: 36.067,
        lng: 140.2045,
        heading: 0,
        speed: 4,
        timestamp: observed,
        serverUpdatedAt: serverUpdated,
        accuracy: 5,
      );

      final extrapolated = evaluator.extrapolateToNow(boat, now: now);
      final distance = distanceMeters(
        LatLng(boat.lat, boat.lng),
        LatLng(extrapolated.lat, extrapolated.lng),
      );
      expect(distance, closeTo(8, 0.2));
      // 古いデータほど外挿誤差マージンが大きくなる。
      expect(
        evaluator.extrapolationAgeSeconds(boat, now: now),
        closeTo(2, 0.01),
      );
      final stale = Boat(
        boatId: 'stale',
        boatType: BoatType.r_1x,
        lat: boat.lat,
        lng: boat.lng,
        heading: 0,
        speed: 4,
        timestamp: observed,
        serverUpdatedAt: now.subtract(const Duration(seconds: 5)),
        accuracy: 5,
      );
      expect(
        evaluator.pairGpsCenterDistanceGuardMeters(boat, boat, now: now),
        lessThan(
          evaluator.pairGpsCenterDistanceGuardMeters(boat, stale, now: now),
        ),
      );
    });
  });

  group('不正な危険区域データ(フェイルセーフ)', () {
    test('頂点2点しかない危険区域でも近くにいれば lv1 以上', () {
      // 区域編集ミスで頂点2点のまま保存されたケース。
      // 以前は例外→無視で完全に無防備だった。
      final myBoat = makeBoat(speed: 0.0);
      final myPos = LatLng(myBoat.lat, myBoat.lng);
      final degenerate = StaticObstacle(
        id: 'segment',
        name: '不正区域',
        points: [
          computeOffset(myPos, 5, 90.0), // 東5m(genericの既定6m以内)
          computeOffset(computeOffset(myPos, 5, 90.0), 20, 0.0),
        ],
      );
      final level = evaluator.evaluateFutureRisk(myBoat, [], [degenerate]);
      expect(level.index, greaterThanOrEqualTo(CollisionRiskLevel.lv1.index));
    });

    test('自己交差した危険区域(蝶ネクタイ型)でも近くにいれば lv1 以上', () {
      final myBoat = makeBoat(speed: 3.0, heading: 0.0);
      final myPos = LatLng(myBoat.lat, myBoat.lng);
      final center = computeOffset(myPos, 8, 0.0); // 8m前方
      // 頂点順序が交差する「蝶ネクタイ」ポリゴン
      final bowtie = StaticObstacle(
        id: 'bowtie',
        name: '自己交差区域',
        points: [
          computeOffset(computeOffset(center, 5, 0), 5, 270), // 北西
          computeOffset(computeOffset(center, 5, 0), 5, 90), // 北東
          computeOffset(computeOffset(center, 5, 180), 5, 270), // 南西
          computeOffset(computeOffset(center, 5, 180), 5, 90), // 南東
        ],
      );
      final level = evaluator.evaluateFutureRisk(myBoat, [], [bowtie]);
      expect(level.index, greaterThanOrEqualTo(CollisionRiskLevel.lv1.index));
    });
  });

  group('異常な艇データ(フェイルセーフ)', () {
    test('speed=NaNの他艇が混ざっても評価が完了し、遠方なら lv0', () {
      // 以前はNaNで予測ループの終了条件が全て不成立となり無限ループ
      // (=アプリ停止・全警告停止)し得たケース。
      final myBoat = makeBoat(speed: 3.0);
      final farPos = computeOffset(LatLng(myBoat.lat, myBoat.lng), 300, 90.0);
      final nanBoat = makeBoat(
        boatId: 'broken',
        lat: farPos.latitude,
        lng: farPos.longitude,
        speed: double.nan,
        heading: double.nan,
      );
      final level = evaluator.evaluateFutureRisk(myBoat, [nanBoat], []);
      expect(level, CollisionRiskLevel.lv0);
    });

    test('lat=NaNの他艇は無視され評価が完了する', () {
      final myBoat = makeBoat(speed: 3.0);
      final nanBoat = makeBoat(
        boatId: 'broken',
        lat: double.nan,
        lng: double.nan,
        speed: 3.0,
      );
      final level = evaluator.evaluateFutureRisk(myBoat, [nanBoat], []);
      expect(level, CollisionRiskLevel.lv0);
    });
  });

  group('GPS誤差(位置不確実性)の考慮', () {
    test('並走12m・双方accuracy 10mでもGPS帯で衝突予測まで上げない', () {
      final myBoat = makeBoat(speed: 3.0, heading: 0.0, accuracy: 10.0);
      final otherPos = computeOffset(LatLng(myBoat.lat, myBoat.lng), 12, 90.0);
      final otherBoat = makeBoat(
        boatId: 'other',
        lat: otherPos.latitude,
        lng: otherPos.longitude,
        heading: 0.0, // 同方向に並走
        speed: 3.0,
        accuracy: 10.0,
      );
      final assessment = evaluator.assessRisk(myBoat, [otherBoat], []);
      // 領域は重ならない = 衝突予測(lv2以上)にはしない。
      expect(
        assessment.level.index,
        lessThanOrEqualTo(CollisionRiskLevel.lv1.index),
      );
      expect(
        assessment.threats.any((threat) =>
            threat.threat.continuousIntersection?.intersects ?? false),
        isFalse,
      );
      // すれ違いの隙間が狭い場合、注意(表示のみ)として記録するのは正しい。
      for (final threat in assessment.threats) {
        expect(threat.level, CollisionRiskLevel.lv1);
        expect(threat.threat.separationMeters, isNotNull);
      }
    });

    test('GPS誤差マージンによる脅威は緊急(lv3)まで上げない', () {
      // 領域そのものは重ならず、マージン込みでのみ重なる場合はlv2止まり
      // (誤差由来の誤報で緊急警報の信頼性を落とさないため)
      final myBoat = makeBoat(speed: 3.0, heading: 0.0);
      final otherPos = computeOffset(LatLng(myBoat.lat, myBoat.lng), 8, 90.0);
      final otherBoat = makeBoat(
        boatId: 'other',
        lat: otherPos.latitude,
        lng: otherPos.longitude,
        heading: 0.0,
        speed: 3.0,
      );
      final level = evaluator.evaluateFutureRisk(myBoat, [otherBoat], []);
      expect(level, CollisionRiskLevel.lv2);
    });

    test('誤差情報がない並走12mでは警告なし(過剰警告の抑制)', () {
      final myBoat = makeBoat(speed: 3.0, heading: 0.0);
      final otherPos = computeOffset(LatLng(myBoat.lat, myBoat.lng), 12, 90.0);
      final otherBoat = makeBoat(
        boatId: 'other',
        lat: otherPos.latitude,
        lng: otherPos.longitude,
        heading: 0.0,
        speed: 3.0,
      );
      final level = evaluator.evaluateFutureRisk(myBoat, [otherBoat], []);
      expect(level, CollisionRiskLevel.lv0);
    });
  });

  group('高速艇とのすれ違い(すり抜け防止)', () {
    test('微速の1xと高速の8+の交差で lv3(以前は判定を飛ばし得た)', () {
      // 自艇: 1x 0.3m/s 北向き。相手: 8+ 5.5m/s 西向き。
      // t≒3.3秒後に自艇位置を8+が横切る。以前の刻み(自艇速度基準
      // dt=6.7s)では衝突の瞬間をまたいでしまうことがあった。
      final myBoat = makeBoat(speed: 0.3, heading: 0.0);
      final myPos = LatLng(myBoat.lat, myBoat.lng);
      // t=3.335sの自艇位置(北1.0m)を通過するように8+を配置
      final crossPoint = computeOffset(myPos, 1.0, 0.0);
      final otherStart = computeOffset(crossPoint, 5.5 * 3.335, 90.0);
      final otherBoat = makeBoat(
        boatId: 'eight',
        lat: otherStart.latitude,
        lng: otherStart.longitude,
        heading: 270.0, // 西へ
        speed: 5.5,
        type: BoatType.r_8p,
      );
      final level = evaluator.evaluateFutureRisk(myBoat, [otherBoat], []);
      expect(level, CollisionRiskLevel.lv3);
    });
  });

  group('予測区間の連続衝突判定', () {
    test('予測終点が通過後でも薄い静的区域の最初の侵入を保持する', () {
      final myBoat = makeBoat(speed: 5.0, heading: 0.0, accuracy: 5.0);
      final obstacleCenter =
          computeOffset(LatLng(myBoat.lat, myBoat.lng), 15, 0.0);
      final thinObstacle = makeSquareObstacle(obstacleCenter, 0.1);

      final result = evaluator.evaluateStaticContinuousIntersection(
        myBoat,
        thinObstacle,
        horizonSeconds: 5,
        includeGpsGuard: false,
      );
      // 掃引そのものは上の `horizonSeconds: 5` で直接確かめている。
      // `assessRisk` 側は下限で clamp されるため、下限を明示して渡す。
      final assessment = evaluator.assessRisk(
        myBoat,
        [],
        [thinObstacle],
        warningTimeSeconds: minWarningTimeSeconds,
      );

      expect(result.intersects, isTrue);
      expect(result.currentOverlap, isFalse);
      expect(result.firstEntryTimeSeconds, inInclusiveRange(1.0, 3.0));
      expect(result.firstExitTimeSeconds, lessThan(5));
      expect(assessment.firstEntryTimeSeconds, isNotNull);
      expect(assessment.level, CollisionRiskLevel.lv3);
    });

    test('航跡線が交差しても到着時刻が違えば他艇衝突にしない', () {
      final myBoat = makeBoat(speed: 2.0, heading: 0.0);
      final myPos = LatLng(myBoat.lat, myBoat.lng);
      final crossing = computeOffset(myPos, 30, 0.0);
      final otherStart = computeOffset(crossing, 20, 90.0);
      final otherBoat = makeBoat(
        boatId: 'early-crossing',
        lat: otherStart.latitude,
        lng: otherStart.longitude,
        heading: 270.0,
        speed: 4.0,
      );

      final result = evaluator.evaluateBoatContinuousIntersection(
        myBoat,
        otherBoat,
        horizonSeconds: 20,
      );

      expect(result.intersects, isFalse);
      expect(result.minimumSeparationMeters, greaterThan(0));
    });

    test('航跡が平行でも後艇が追いつく場合は検知する', () {
      final myBoat = makeBoat(speed: 3.0, heading: 0.0);
      final otherPos = computeOffset(
        computeOffset(LatLng(myBoat.lat, myBoat.lng), 15, 0.0),
        5,
        90.0,
      );
      final otherBoat = makeBoat(
        boatId: 'overtaken',
        lat: otherPos.latitude,
        lng: otherPos.longitude,
        heading: 0.0,
        speed: 1.0,
      );

      final result = evaluator.evaluateBoatContinuousIntersection(
        myBoat,
        otherBoat,
        horizonSeconds: 10,
        includeGpsGuard: false,
      );

      expect(result.intersects, isTrue);
      expect(result.firstEntryTimeSeconds, inInclusiveRange(1.0, 6.0));
    });

    test('現在すでに重なる場合はfirstEntryTime=0', () {
      final myBoat = makeBoat(speed: 3.0, heading: 0.0);
      final otherBoat = makeBoat(
        boatId: 'overlap',
        lat: myBoat.lat,
        lng: myBoat.lng,
        speed: 3.0,
        heading: 180.0,
      );

      final result = evaluator.evaluateBoatContinuousIntersection(
        myBoat,
        otherBoat,
        horizonSeconds: 10,
      );

      expect(result.currentOverlap, isTrue);
      expect(result.firstEntryTimeSeconds, 0);
    });
  });

  group('swept domainのGPS補助帯', () {
    test('accuracy 5mの静的補助は片側0.625mで、旧余裕入り区域は0m', () {
      final boat = makeBoat(accuracy: 5.0);
      final obstacle = makeSquareObstacle(LatLng(boat.lat, boat.lng), 2);
      final legacy = StaticObstacle(
        id: 'legacy',
        points: obstacle.points,
        isDefault: true,
        proximityCautionDistanceMeters: 0,
      );

      // 同梱プリセットだけGPS帯を0にする特例は撤去した。区域の種類に
      // 関係なく accuracy から一様に求める。
      expect(evaluator.staticGpsInflatePerSideMeters(boat, obstacle), 0.625);
      expect(evaluator.staticGpsInflatePerSideMeters(boat, legacy), 0.625);
    });

    test('双方accuracy 5mの他艇補正は中心間距離へ約1.414m加える', () {
      final now = DateTime.now();
      final a = makeBoat(boatId: 'a', accuracy: 5.0);
      final b = makeBoat(boatId: 'b', accuracy: 5.0);
      // sqrt(50) × 0.20 = 1.4142。makeBoatのtimestampはnow相当なので
      // 外挿マージンは0。
      expect(
        evaluator.pairGpsCenterDistanceGuardMeters(a, b, now: now),
        closeTo(1.4142, 0.01),
      );
    });

    test('静的補助は片側1.5m、他艇のaccuracy補正は2.5mが上限', () {
      final now = DateTime.now();
      final a = makeBoat(boatId: 'a', accuracy: 100.0);
      final b = makeBoat(boatId: 'b', accuracy: 100.0);
      final obstacle = makeSquareObstacle(LatLng(a.lat, a.lng), 2);
      expect(evaluator.staticGpsInflatePerSideMeters(a, obstacle), 1.5);
      expect(
        evaluator.pairGpsCenterDistanceGuardMeters(a, b, now: now),
        closeTo(2.5, 0.01),
      );
    });

    test('外挿マージンはデータ齢に比例し、上限2.5mで頭打ちになる', () {
      final now = DateTime.now();
      Boat aged(int seconds) => Boat(
            boatId: 'aged',
            boatType: BoatType.r_1x,
            lat: 36.0670,
            lng: 140.2045,
            heading: 0,
            speed: 4,
            timestamp: now,
            serverUpdatedAt: now.subtract(Duration(seconds: seconds)),
            accuracy: 5,
          );
      final fresh = makeBoat(boatId: 'own', accuracy: 5.0);
      double guard(int seconds) => evaluator
          .pairGpsCenterDistanceGuardMeters(fresh, aged(seconds), now: now);

      // accuracy分は1.4142で固定。差分が外挿マージン。
      expect(guard(0) - 1.4142, closeTo(0, 0.02));
      expect(guard(2) - 1.4142, closeTo(0.8, 0.02));
      expect(guard(5) - 1.4142, closeTo(2.0, 0.02));
      // 予測に使える鮮度(6秒)で齢が頭打ちになるため2.4mが最大。
      expect(guard(30) - 1.4142, closeTo(2.4, 0.02));
      expect(guard(30) - 1.4142, lessThanOrEqualTo(2.5));
    });

    test('近接注意距離は区域の種類ごとに変える', () {
      expect(StaticObstacleKind.shore.defaultProximityCautionMeters, 3.0);
      expect(StaticObstacleKind.bridge.defaultProximityCautionMeters, 6.0);
      expect(StaticObstacleKind.bridgePier.defaultProximityCautionMeters, 6.0);
      expect(StaticObstacleKind.island.defaultProximityCautionMeters, 5.0);
      expect(StaticObstacleKind.driftwood.defaultProximityCautionMeters, 6.0);
      // 案内区域は近接判定の対象外。
      expect(StaticObstacleKind.curve.defaultProximityCautionMeters, 0.0);
      // すべて索引の問い合わせ半径の上界以下であること。
      for (final kind in StaticObstacleKind.values) {
        expect(
          kind.defaultProximityCautionMeters,
          lessThanOrEqualTo(15.0),
        );
      }
    });
  });
}
