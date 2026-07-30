import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/config/boat_config.dart';
import 'package:rowing_navigator/config/risk_evaluator_config.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import 'package:rowing_navigator/models/danger_zone_settings.dart';
import 'package:rowing_navigator/models/static_obstacle_model.dart';
import 'package:rowing_navigator/services/channel_centerline.dart';
import 'package:rowing_navigator/services/collision_risk_evaluator_service.dart';
import 'package:rowing_navigator/services/legacy_danger_zone_generator.dart';
import 'package:rowing_navigator/services/preset_obstacle_service.dart';
import 'package:rowing_navigator/services/ship_domain_service.dart';
import 'package:rowing_navigator/types/boat_type.dart';
import 'package:rowing_navigator/utils/geo_math.dart';
import 'package:rowing_navigator/utils/geo_proximity.dart';
import 'package:rowing_navigator/utils/heading.dart';
import 'package:rowing_navigator/utils/relative_direction.dart';

/// 実データ(assets/data/sakuragawa_obstacles.json)を使う統合テスト。
///
/// DESIGN_PRINCIPLES 3.5-2「掃引による岸への警告が右側通行の通常操舵で
/// 立たないか、実測で確認する」への回帰テスト。設定値の意図(kind別
/// クリアランス)と実効値(実際に何mで鳴るか)の乖離を検出する。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 岸基準線の中から、テストに使う「川沿いの直線区間」を1つ選ぶ。
  ///
  /// - 蛇行区間では「岸と平行」自体が定義できないので、方位がほぼ一定な
  ///   最長区間を採る。
  /// - shore_north は霞ヶ浦側まで7.6km続いており、川沿いでない区間も含む。
  ///   航路中心線から10〜40mの範囲に収まる区間だけを対象にする。
  /// - 水面側は基準線の頂点順から決まる(LegacyDangerZoneGenerator は
  ///   進行方位-90度を水面側とする)が、頂点順はデータ側の都合なので、
  ///   「中心線に近づく側」を水面側として実データから求める。
  ///
  /// 実データは固定なので、選ばれる区間も毎回同じになる。
  ({
    LatLng start,
    double bearingDegrees,
    double waterBearingDegrees,
    double lengthMeters,
  }) riverStraight(
    List<LatLng> baseline,
    ChannelCenterline centerline, {
    double toleranceDegrees = 2.0,
  }) {
    ({
      LatLng start,
      double bearingDegrees,
      double waterBearingDegrees,
      double lengthMeters,
    })? best;
    for (var i = 0; i < baseline.length - 1; i++) {
      final bearing = getHeading(baseline[i], baseline[i + 1]);
      var length = 0.0;
      var j = i;
      while (j < baseline.length - 1) {
        final segmentBearing = getHeading(baseline[j], baseline[j + 1]);
        if (relativeBearingDegrees(bearing, segmentBearing).abs() >
            toleranceDegrees) {
          break;
        }
        length += distanceMeters(baseline[j], baseline[j + 1]);
        j++;
      }
      final frame = centerline.project(baseline[i]);
      if (!frame.isInsideCoverage) continue;
      final offsetFromCenterline = frame.crossMeters.abs();
      if (offsetFromCenterline < 10 || offsetFromCenterline > 40) continue;
      if (best != null && length <= best.lengthMeters) continue;
      // 中心線へ近づくほうが水面側。
      double distanceToCenterline(double towards) {
        final probe = computeOffset(baseline[i], 5, towards);
        return centerline.project(probe).crossMeters.abs();
      }

      final waterBearing = distanceToCenterline(bearing - 90) <
              distanceToCenterline(bearing + 90)
          ? bearing - 90
          : bearing + 90;
      best = (
        start: baseline[i],
        bearingDegrees: bearing,
        waterBearingDegrees: waterBearing,
        lengthMeters: length,
      );
    }
    return best!;
  }

  /// 基準線から水面側へ [offsetMeters] 離れた地点を、基準線と平行に走る艇。
  Boat parallelBoat({
    required LatLng start,
    required double bearingDegrees,
    required double waterBearingDegrees,
    required double alongMeters,
    required double offsetMeters,
    double speed = 4,
    double accuracyMeters = assumedGpsAccuracyMeters,
    BoatType type = BoatType.r_1x,
  }) {
    final onBaseline = computeOffset(start, alongMeters, bearingDegrees);
    final position =
        computeOffset(onBaseline, offsetMeters, waterBearingDegrees);
    return Boat(
      boatId: 'own',
      boatType: type,
      lat: position.latitude,
      lng: position.longitude,
      heading: bearingDegrees,
      speed: speed,
      timestamp: DateTime.now(),
      accuracy: accuracyMeters,
    );
  }

  late List<StaticObstacle> shoreZones;
  late List<LatLng> shoreBaseline;
  late ({
    LatLng start,
    double bearingDegrees,
    double waterBearingDegrees,
    double lengthMeters,
  }) straight;

  setUpAll(() async {
    final service = PresetObstacleService(
      includeTestZones: false,
      useLocalDangerZoneSettings: false,
      useLocalFixedObstacleCalibrations: false,
    );
    final centerline = await service.loadChannelCenterline();
    final targets = await service.loadCalibrationTargets();
    shoreBaseline = targets
        .firstWhere((target) => target.sourceId == 'shore_north')
        .sourcePoints;
    straight = riverStraight(shoreBaseline, centerline!);

    // 岸の危険区域は、実運用の設定値(DESIGN_PRINCIPLES 1.1「岸の基準線から
    // 水面側へ約5m」)で生成する。`DangerZoneSettings.defaults()` は
    // 水面側も15mで、実機の運用設定(manifest確認済みの waterSide 5.0 /
    // landSide 15.0)とは別物なので、ここで明示的に固定する。
    // 座標そのものは同梱プロファイルの実データを使う。
    final settings = DangerZoneSettings.defaults().withOffsets(
      DangerZoneKind.shore,
      const DangerZoneOffsets(waterSideMeters: 5, landSideMeters: 15),
    );
    shoreZones = LegacyDangerZoneGenerator().generate(
      baselines: targets
          .where((target) => target.kind == StaticObstacleKind.shore)
          .map((target) => DangerZoneBaseline(
                id: target.sourceId,
                name: target.name,
                kind: DangerZoneKind.shore,
                points: target.sourcePoints,
              ))
          .toList(growable: false),
      settings: settings,
    );
  });

  /// 岸区域だけの実データ。他カテゴリの脅威と混ざらないようにする。
  List<StaticObstacle> shoreObstacles() => shoreZones;

  /// 同じ形状のまま kind だけ差し替える。
  /// 「変わったのはクリアランスだけで、幾何や位置ではない」ことを示すため。
  List<StaticObstacle> recolored(
    List<StaticObstacle> source,
    StaticObstacleKind kind,
  ) =>
      source
          .map((obstacle) => StaticObstacle(
                id: obstacle.id,
                sourceId: obstacle.sourceId,
                name: obstacle.name,
                points: obstacle.points,
                isDefault: obstacle.isDefault,
                // 近接注意は kind ごとに既定値が違うので、掃引だけを見るため
                // 明示的に0へ揃える(0でも区域内部は必ず拾われる)。
                proximityCautionDistanceMeters: 0,
                kind: kind,
              ))
          .toList(growable: false);

  bool firesAt(
    List<StaticObstacle> obstacles,
    double offsetMeters, {
    BoatType type = BoatType.r_1x,
    double accuracyMeters = assumedGpsAccuracyMeters,
  }) {
    final evaluator = CollisionRiskEvaluatorService();
    final boat = parallelBoat(
      start: straight.start,
      bearingDegrees: straight.bearingDegrees,
      waterBearingDegrees: straight.waterBearingDegrees,
      // 予測地平(10秒 × 4m/s = 40m)が直線区間の中に収まる位置から走らせる。
      alongMeters: 20,
      offsetMeters: offsetMeters,
      accuracyMeters: accuracyMeters,
      type: type,
    );
    final assessment = evaluator.assessRisk(
      boat,
      const [],
      obstacles,
      warningTimeSeconds: defaultWarningTimeSeconds,
    );
    return assessment.threats.isNotEmpty;
  }

  /// 発報が始まる基準線からの距離 [m]。0.05m刻みで外側から詰める。
  double firstAlertOffsetMeters(
    List<StaticObstacle> obstacles, {
    double accuracyMeters = assumedGpsAccuracyMeters,
  }) {
    for (var offset = 20.0; offset >= 4.0; offset -= 0.05) {
      if (firesAt(obstacles, offset, accuracyMeters: accuracyMeters)) {
        return offset;
      }
    }
    return double.nan;
  }

  group('静的危険区域の掃引クリアランス(実データ)', () {
    test('前提: 桜川の岸基準線に十分長い直線区間がある', () {
      expect(shoreBaseline.length, greaterThan(100));
      expect(straight.lengthMeters, greaterThan(120),
          reason: '「岸と平行に走る」を定義できる区間が要る');
    });

    test('狭所レーン中央(岸の基準線から11.25m)を並走しても発報しない', () {
      // DESIGN_PRINCIPLES 1.2: 狭所は川幅35m・実効航路幅25m・片側レーン12.5m。
      // 岸区域の水面側5m + レーン半幅6.25m = 艇中心は岸から11.25m。
      // 規定どおり漕いで鳴るなら、それは安全側の設計ではなく不具合(原則4)。
      expect(firesAt(shoreObstacles(), 11.25), isFalse);
      // GPS帯が上限(片側1.5m)まで開く劣化時でも余裕が残ること。
      expect(firesAt(shoreObstacles(), 11.25, accuracyMeters: 15), isFalse);
      // 境界の上に正常運用を乗せない。2m以上の余裕を不変条件にする。
      expect(firesAt(shoreObstacles(), 9.5), isFalse);
    });

    test('岸の基準線から8mまで寄ると発報する(オール先端が区域に入る)', () {
      // 岸区域は基準線から水面側5m。1x の船体領域は片側3.0m なので、
      // 8m で船体+オールが区域へ触れる。警告漏れにはしない。
      expect(firesAt(shoreObstacles(), 8.0), isTrue);
      expect(firesAt(shoreObstacles(), 6.0), isTrue);
    });

    test('岸だけがクリアランス0で、同じ形状でも他カテゴリは従来どおり', () {
      final shoreStart = firstAlertOffsetMeters(shoreObstacles());
      // 形状・位置は同一のまま kind だけ中州にすると、既定クリアランス1.5m
      // (=排他領域と同じ横幅)で判定されるため、従来どおり遠くで鳴る。
      // これが変更前の岸の挙動そのものである。
      final legacy = recolored(shoreObstacles(), StaticObstacleKind.island);
      final legacyStart = firstAlertOffsetMeters(legacy);
      final shoreDegraded =
          firstAlertOffsetMeters(shoreObstacles(), accuracyMeters: 15);
      final legacyDegraded = firstAlertOffsetMeters(legacy, accuracyMeters: 15);
      // ignore: avoid_print
      print('発報開始距離(岸の基準線から) '
          'accuracy=5m: 変更後 ${shoreStart.toStringAsFixed(2)}m / '
          '変更前相当 ${legacyStart.toStringAsFixed(2)}m、'
          'accuracy=15m: 変更後 ${shoreDegraded.toStringAsFixed(2)}m / '
          '変更前相当 ${legacyDegraded.toStringAsFixed(2)}m');

      expect(shoreStart, lessThan(legacyStart - 1.0),
          reason: '岸だけ発報開始が内側へ寄ること(横幅を片側1.5m詰めた分)');
      expect(shoreDegraded, lessThan(legacyDegraded - 1.0));
      // 変更前は狭所レーン中央(11.25m)のすぐ内側(0.25m)で鳴り始めていた。
      // 通常の操舵のふらつきやGPS雑音で必ず境界を跨ぐ = 常時発報になる。
      expect(legacyDegraded, greaterThan(10.5));
      expect(11.25 - legacyDegraded, lessThan(0.5));
      // 変更後は、GPS帯が上限まで開いた劣化時でも1.5m以上、
      // 通常(accuracy 5m)なら2.5m以上の余裕がある。
      expect(11.25 - shoreDegraded, greaterThan(1.5));
      expect(11.25 - shoreStart, greaterThan(2.5));
      // 9.5m の並走は、変更前は鳴り、変更後は鳴らない。
      expect(firesAt(legacy, 9.5), isTrue);
      expect(firesAt(shoreObstacles(), 9.5), isFalse);
    });

    test('岸へ向かって進む艇の検知時刻は、クリアランスを変えても同じ', () {
      // 前後方向(h)と s は排他領域のまま変えていないので、
      // 正面から突っ込むケースの到達時刻は一致しなければならない。
      final evaluator = CollisionRiskEvaluatorService();
      // 直線区間の中央の基準線上の点。ここへ水面側から真っ直ぐ突っ込む。
      final aimPoint = computeOffset(
        straight.start,
        straight.lengthMeters / 2,
        straight.bearingDegrees,
      );
      final target = shoreObstacles().reduce((a, b) =>
          minDistanceToPolygonMeters(aimPoint, a.points) <
                  minDistanceToPolygonMeters(aimPoint, b.points)
              ? a
              : b);
      final shore = StaticObstacle(
        id: target.id,
        points: target.points,
        kind: StaticObstacleKind.shore,
        proximityCautionDistanceMeters: 0,
      );
      final island = StaticObstacle(
        id: target.id,
        points: target.points,
        kind: StaticObstacleKind.island,
        proximityCautionDistanceMeters: 0,
      );

      final origin = computeOffset(aimPoint, 40, straight.waterBearingDegrees);
      final boat = Boat(
        boatId: 'own',
        boatType: BoatType.r_1x,
        lat: origin.latitude,
        lng: origin.longitude,
        // 岸へ向かう向き(水面側から陸側へ)。
        heading: (straight.waterBearingDegrees + 180) % 360,
        speed: 5,
        timestamp: DateTime.now(),
        accuracy: 5,
      );

      final shoreEntry = evaluator
          .evaluateStaticContinuousIntersection(boat, shore, horizonSeconds: 12)
          .firstEntryTimeSeconds;
      final islandEntry = evaluator
          .evaluateStaticContinuousIntersection(boat, island,
              horizonSeconds: 12)
          .firstEntryTimeSeconds;

      expect(shoreEntry, isNotNull, reason: '岸へ向かう艇は必ず検知すること');
      expect(islandEntry, isNotNull);
      expect(shoreEntry!, closeTo(islandEntry!, 1e-6),
          reason: '前後方向(h)を変えていないので到達時刻は一致する');
    });

    test('既定クリアランス1.5mの掃引領域は、全艇種で排他領域と同じ寸法', () {
      for (final type in BoatType.values) {
        final boat = Boat(
          boatId: 'own',
          boatType: type,
          lat: 36.08,
          lng: 140.12,
          heading: 0,
          speed: 4,
          timestamp: DateTime.now(),
        );
        final exclusive =
            boatConfigs.byBoatType(type).shipDomainParams.exclusiveParam;
        for (final kind in [
          StaticObstacleKind.bridge,
          StaticObstacleKind.island,
          StaticObstacleKind.driftwood,
          StaticObstacleKind.generic,
          StaticObstacleKind.testZone,
        ]) {
          expect(kind.staticSweepClearanceMeters,
              defaultStaticSweepClearanceMeters);
          final param = ShipDomainService.staticSweepParam(
            boat,
            clearancePerSideMeters: kind.staticSweepClearanceMeters,
          );
          expect(param.h, exclusive.h, reason: '$type / $kind');
          expect(param.w, closeTo(exclusive.w, 1e-9), reason: '$type / $kind');
          expect(param.s, exclusive.s, reason: '$type / $kind');
        }
        // 岸だけが船体領域の実寸。
        final shoreParam = ShipDomainService.staticSweepParam(
          boat,
          clearancePerSideMeters:
              StaticObstacleKind.shore.staticSweepClearanceMeters,
        );
        expect(shoreParam.w,
            boatConfigs.byBoatType(type).shipDomainParams.shipBodyParam.w);
        expect(shoreParam.h, exclusive.h);
        expect(shoreParam.s, exclusive.s);
        // 不変条件9: 六角形の凸性。
        expect(shoreParam.s, lessThanOrEqualTo(shoreParam.h));
      }
    });

    test('不変条件8: 掃引領域の外接円半径は排他領域の実効半径を超えない', () {
      for (final type in BoatType.values) {
        // 高速(方位が信頼できる)と低速(横拡張あり)の両方。
        for (final speed in [4.0, 0.1]) {
          final boat = Boat(
            boatId: 'own',
            boatType: type,
            lat: 36.08,
            lng: 140.12,
            heading: 0,
            speed: speed,
            timestamp: DateTime.now(),
          );
          final limit = ShipDomainService.effectiveExclusiveRadius(boat);
          for (final clearance in [
            shoreStaticSweepClearanceMeters,
            defaultStaticSweepClearanceMeters,
            // 設定を取り違えて過大な値を渡しても broad-phase を破らないこと。
            5.0,
          ]) {
            final radius = ShipDomainService.boundingRadius(
              ShipDomainService.staticSweepParam(
                boat,
                clearancePerSideMeters: clearance,
              ),
            );
            expect(radius, lessThanOrEqualTo(limit + 1e-9),
                reason: '$type / speed=$speed / clearance=$clearance');
          }
        }
      }
    });
  });
}
