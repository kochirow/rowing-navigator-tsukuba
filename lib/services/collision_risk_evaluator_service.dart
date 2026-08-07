import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/config/boat_config.dart';
import 'package:rowing_navigator/utils/sat_algorithm.dart';
import 'package:rowing_navigator/services/ship_domain_service.dart';

import '../config/risk_evaluator_config.dart';
import '../models/boat_model.dart';
import '../models/channel_lane.dart';
import '../models/protection_budget.dart';
import '../models/static_obstacle_model.dart';
import '../services/channel_centerline.dart';
import '../services/channel_lane_resolver.dart';
import '../services/channel_path_predictor.dart';
import '../services/continuous_collision_service.dart';
import '../services/static_obstacle_index.dart';
import '../services/bounded_position_set.dart';
import '../types/collision_risk_level.dart';
import '../utils/geo_math.dart';
import '../utils/geo_proximity.dart';
import '../utils/heading.dart';
import '../utils/mean_lat_lng.dart';
import '../utils/relative_direction.dart';
import '../utils/winding_algorithm.dart';

// 状況を表すクラス
class Situation {
  final Boat myBoat;
  final List<Boat> otherBoats;
  final List<StaticObstacle> obstacles;

  Situation({
    required this.myBoat,
    required this.otherBoats,
    required this.obstacles,
  });
}

/// 脅威の種類
enum ThreatKind { boat, obstacle }

/// 脅威判定の確度
/// - definite: 領域そのものが重なった(GPSが正確なら衝突コース)
/// - uncertain: GPS誤差・データの古さのマージンを考慮すると重なる、
///   または幾何判定が失敗し保守的な距離判定で脅威とみなした
enum ThreatConfidence { definite, uncertain }

/// 逆走注意区域(`StaticObstacleKind.reverse`)の方向つき判定の結果。
enum ReverseGuidanceOutcome {
  /// 規定進行方位から大きくずれている = 逆走。発報する。
  reverse,

  /// 規定どおり進んでいる、または方位が意味を持たない。発報しない。
  compliant,

  /// レーンが明示されているが、そのどれにも入っていない。作図者が指定した
  /// 非判定領域なので、`unverified` のような区域内発報へは縮退しない。
  laneUndetermined,

  /// 方向を確かめられなかった。従来どおり「区域内にいれば発報」へ縮退する。
  unverified,
}

/// 検知された脅威の情報(対象別の警告音・表示用)
class ThreatInfo {
  final ThreatKind kind;
  final LatLng position; // 脅威のおおよその位置(方向の読み上げに使用)
  final ThreatConfidence confidence;
  final StaticObstacleKind? obstacleKind;
  final String? obstacleId;

  /// 危険区域の生成元(基準線)ID。
  ///
  /// 岸・橋は基準線の各辺が独立した長方形へ展開されるため、`obstacleId` は
  /// 「北岸の126番目の辺」のような実装都合の単位になる。提示・音声の集約は
  /// 人が認識する単位(「北岸」「桜川橋」)で行う必要があるので、
  /// [StaticObstacle.sourceId] をここまで運ぶ。
  final String? obstacleSourceId;
  final String? obstacleBridgeId;
  final String? obstacleName;
  final String? warningAudioAsset;
  final String? boatId;
  final String? boatSessionId;

  /// 危険源までの符号付き距離 [m]。危険区域の内部では負。
  final double? distanceMeters;

  /// 自艇針路を基準にした脅威の相対方位 [度](-180〜180、正が右舷側)。
  ///
  /// 漕手は進行方向を見ていないため、振り向く側を伝えるために使う。
  /// 危険区域は重心ではなく最寄りの辺上の点を基準にする。
  final double? relativeBearingDegrees;

  /// 予測区間での安全領域どうしの最接近距離 [m](DCPA相当)。
  /// 重なる場合は0。領域間の隙間なので、艇体間の実距離はこれより広い。
  final double? separationMeters;
  final ContinuousIntersection? continuousIntersection;

  ThreatInfo({
    required this.kind,
    required this.position,
    this.confidence = ThreatConfidence.definite,
    this.obstacleKind,
    this.obstacleId,
    this.obstacleSourceId,
    this.obstacleBridgeId,
    this.obstacleName,
    this.warningAudioAsset,
    this.boatId,
    this.boatSessionId,
    this.distanceMeters,
    this.relativeBearingDegrees,
    this.separationMeters,
    this.continuousIntersection,
  });
}

/// 複数の警告対象を同時に上位へ渡すための個別判定。
class RiskThreat {
  final CollisionRiskLevel level;
  final ThreatInfo threat;

  const RiskThreat({required this.level, required this.threat});
}

/// リスク評価の結果
class RiskAssessment {
  final CollisionRiskLevel level;
  final ThreatInfo? primaryThreat; // 最も高いリスクを生じさせた脅威
  final List<RiskThreat> threats;
  final ContinuousIntersection? continuousIntersection;

  RiskAssessment({
    required this.level,
    this.primaryThreat,
    Iterable<RiskThreat>? threats,
    ContinuousIntersection? continuousIntersection,
  })  : threats = _immutableThreats(threats, level, primaryThreat),
        continuousIntersection =
            continuousIntersection ?? primaryThreat?.continuousIntersection;

  static List<RiskThreat> _immutableThreats(
    Iterable<RiskThreat>? threats,
    CollisionRiskLevel level,
    ThreatInfo? primaryThreat,
  ) {
    if (threats != null) return List<RiskThreat>.unmodifiable(threats);
    if (primaryThreat == null) return const <RiskThreat>[];
    return List<RiskThreat>.unmodifiable([
      RiskThreat(level: level, threat: primaryThreat),
    ]);
  }

  bool get currentOverlap => continuousIntersection?.currentOverlap ?? false;
  double? get firstEntryTimeSeconds =>
      continuousIntersection?.firstEntryTimeSeconds;
  double? get firstEntryDistanceMeters =>
      continuousIntersection?.firstEntryDistanceMeters;
  double? get minimumSeparationMeters =>
      continuousIntersection?.minimumSeparationMeters;
}

class CollisionRiskEvaluatorService {
  final ShipDomainService _shipDomainService = ShipDomainService();
  final ContinuousCollisionService _continuousCollisionService =
      ContinuousCollisionService();
  final ChannelPathPredictor _pathPredictor = const ChannelPathPredictor();
  List<StaticObstacle>? _indexedSource;
  StaticObstacleIndex? _obstacleIndex;

  /// 障害物リストの索引を、リストの同一性でキャッシュする。
  ///
  /// `obstacles` は内容が変わったときだけ新しいListへ差し替わるため、
  /// 参照が同じなら索引を再構築しない。1Hzで310枚を全走査していた無駄を
  /// 周辺の数枚へ絞る。索引は判定結果を変えない(保守的な上位集合)。
  StaticObstacleIndex _indexFor(List<StaticObstacle> obstacles) {
    final cached = _obstacleIndex;
    if (cached != null && identical(_indexedSource, obstacles)) return cached;
    final index = StaticObstacleIndex(obstacles);
    _indexedSource = obstacles;
    _obstacleIndex = index;
    return index;
  }

  /// 予測区間を折れ線へ分けたとき、区間ごとの結果を全体の時間軸へ戻す。
  ///
  /// `currentOverlap` は「いま重なっている」という意味なので、
  /// 開始時刻0の区間からしか立てない。
  static ContinuousIntersection _shiftIntersectionTime(
    ContinuousIntersection result,
    double offsetSeconds,
  ) {
    if (!result.intersects || offsetSeconds <= 0) return result;
    return ContinuousIntersection(
      intersects: true,
      currentOverlap: false,
      firstEntryTimeSeconds:
          (result.firstEntryTimeSeconds ?? 0) + offsetSeconds,
      firstExitTimeSeconds: (result.firstExitTimeSeconds ?? 0) + offsetSeconds,
      minimumSeparationMeters: result.minimumSeparationMeters,
      confidence: result.confidence,
      reasonCodes: result.reasonCodes,
    );
  }

  /// 区間の始点・進行方位・速度を持つ仮想的な艇を作る。
  /// 折れ線の各区間で艇の領域を正しい向きに置くために使う。
  Boat _boatOnSegment(Boat boat, PredictedMotionSegment segment) => Boat(
        boatId: boat.boatId,
        displayName: boat.displayName,
        boatType: boat.boatType,
        lat: segment.origin.latitude,
        lng: segment.origin.longitude,
        heading: segment.headingDegrees,
        speed: segment.speedMetersPerSecond,
        timestamp: boat.timestamp,
        battery: boat.battery,
        accuracy: boat.accuracy,
        sessionId: boat.sessionId,
        serverUpdatedAt: boat.serverUpdatedAt,
      );

  /// 予測区間で川がどれだけ曲がるかから、横方向マージン [m] を求める。
  ///
  /// 相対運動の直線掃引(他艇判定)は川の湾曲を表現できないため、
  /// 弦の中央のずれ(サジッタ ≒ L·Δθ/8)ぶんを領域へ加えて補う。
  double channelCurvatureMarginMeters(
    Boat boat,
    double horizonSeconds,
    ChannelCenterline? centerline,
  ) {
    if (!enableChannelAwarePrediction || centerline == null) return 0;
    final speed = boat.speed.isFinite && boat.speed > 0 ? boat.speed : 0.0;
    final travel = speed * horizonSeconds;
    if (!travel.isFinite || travel <= 0) return 0;
    final frame = centerline.project(LatLng(boat.lat, boat.lng));
    if (!frame.isInsideCoverage ||
        frame.crossMeters.abs() > maxChannelProjectionOffsetMeters) {
      return 0;
    }
    final endAlong =
        (frame.alongMeters + travel).clamp(0.0, centerline.lengthMeters);
    var turn = (centerline.tangentBearingAt(endAlong) -
            centerline.tangentBearingAt(frame.alongMeters)) %
        360;
    if (turn > 180) turn -= 360;
    final turnRadians = degreesToRadians(turn).abs();
    return min(maxChannelCurvatureMarginMeters, travel * turnRadians / 8);
  }

  /// 異常値(NaN/Infinity/範囲外)を安全に扱えるよう艇情報を正規化する。
  /// - 位置(lat/lng)が使えない場合はnull(その艇は幾何判定不能)
  /// - 方位が異常なら0度、速度が異常・負なら0(停止扱い)に丸める
  /// 1艇の異常データが評価ループ全体を壊す(=全警告が止まる)ことを防ぐ。
  Boat? _usableBoat(Boat b) {
    if (!b.lat.isFinite ||
        !b.lng.isFinite ||
        b.lat.abs() > 90 ||
        b.lng.abs() > 180) {
      return null;
    }
    final heading = b.heading.isFinite ? b.heading : 0.0;
    final speed = (b.speed.isFinite && b.speed > 0) ? b.speed : 0.0;
    if (heading == b.heading && speed == b.speed) return b;
    return Boat(
      boatId: b.boatId,
      displayName: b.displayName,
      boatType: b.boatType,
      lat: b.lat,
      lng: b.lng,
      heading: heading,
      speed: speed,
      timestamp: b.timestamp,
      battery: b.battery,
      accuracy: b.accuracy,
      sessionId: b.sessionId,
      serverUpdatedAt: b.serverUpdatedAt,
    );
  }

  /// 推測航法(外挿)で進んだ時間 [秒]。
  ///
  /// 他艇端末のwall clockは数秒ずれ得るため、Firebaseサーバー時刻を優先する。
  /// 観測端末のtimestampを使うと、時計が遅い艇を現在位置より先へ
  /// 過剰外挿し得る。上限は予測に使える鮮度で切る。
  double extrapolationAgeSeconds(Boat boat, {DateTime? now}) {
    final reference = boat.serverUpdatedAt ?? boat.timestamp;
    final seconds =
        (now ?? DateTime.now()).difference(reference).inMilliseconds / 1000.0;
    if (!seconds.isFinite || seconds < 0) return 0;
    return min(seconds, boatPredictionTimeoutSeconds.toDouble());
  }

  /// 自艇から見た [target] の相対方位 [度]。方位が使えないときは null。
  ///
  /// 自艇が停止・回頭中(`headingIsReliable` false)のときは保持している
  /// 進行方位が実際の艇の向きと最大90度ずれるため、方向案内には使わない。
  /// 誤った方向へ振り向かせるより、方向を出さないほうが安全。
  double? _relativeBearingTo(Boat myBoat, LatLng? target) {
    if (target == null) return null;
    if (!ShipDomainService.headingIsReliable(myBoat)) return null;
    if (!myBoat.heading.isFinite) return null;
    final origin = LatLng(myBoat.lat, myBoat.lng);
    if (distanceMeters(origin, target) < 1e-3) return null;
    final bearing = getHeading(origin, target);
    if (!bearing.isFinite) return null;
    return relativeBearingDegrees(myBoat.heading, bearing);
  }

  /// 危険区域は重心ではなく、最寄りの辺上の点を方向の基準にする。
  double? _relativeBearingToObstacle(Boat myBoat, StaticObstacle obstacle) =>
      _relativeBearingTo(
        myBoat,
        nearestPointOnPolygon(LatLng(myBoat.lat, myBoat.lng), obstacle.points),
      );

  double _gpsAccuracyMeters(Boat boat) {
    final accuracy = boat.accuracy;
    if (accuracy == null || !accuracy.isFinite || accuracy <= 0) {
      return assumedGpsAccuracyMeters;
    }
    return accuracy;
  }

  /// 静的障害物に対するGPS補助帯の片側拡張量 [m]。
  ///
  /// accuracyの0.25倍を「全幅」へ加え、その半分だけを各側へ加える。
  /// 以前は同梱プリセットだけ0にする特例があり、「確実(lv3)/不確実(lv2)」の
  /// 2段判定が静的区域では同じ計算を2回するだけになっていた。特例は撤去した。
  double staticGpsInflatePerSideMeters(Boat boat, StaticObstacle obstacle) {
    final fullWidth = (_gpsAccuracyMeters(boat) * staticGpsGuardFullWidthFactor)
        .clamp(0.0, maxStaticGpsGuardFullWidthMeters)
        .toDouble();
    return fullWidth / 2;
  }

  /// 他艇の速度が使えるか。**取れないときは false**(原則6)。
  static bool _isSpeedKnown(Boat boat) =>
      boat.speed.isFinite && boat.speed >= 0;

  /// 他艇の方位が使えるか。
  static bool _isHeadingKnown(Boat boat) => boat.heading.isFinite;

  /// 2艇の相対幾何へ加える保護量の内訳。
  ///
  /// 合計だけでなく由来別に返すのは、「なぜ帯が広いのか」を説明できる
  /// ようにするため。通信遅延で広いのか自艇のGNSSが悪いのかで、
  /// 表示も復旧手段も違う。詳細は [ProtectionBudget]。
  ProtectionBudget pairProtectionBudget(Boat a, Boat b, {DateTime? now}) {
    final accuracyA = _gpsAccuracyMeters(a);
    final accuracyB = _gpsAccuracyMeters(b);
    // 近接した2端末のGNSS誤差は共通成分が相殺するため、係数は1.0より小さい。
    final accuracyGuard = (sqrt(accuracyA * accuracyA + accuracyB * accuracyB) *
            pairGpsCenterDistanceGuardFactor)
        .clamp(0.0, maxPairGpsCenterDistanceGuardMeters)
        .toDouble();
    // 自艇は測位直後なので齢はほぼ0。実際に効くのは受信した他艇側。
    final ageSeconds = max(
      extrapolationAgeSeconds(a, now: now),
      extrapolationAgeSeconds(b, now: now),
    );
    final extrapolationGuard = min(
      extrapolationUncertaintyMetersPerSecond * ageSeconds,
      maxExtrapolationGuardMeters,
    );
    // ---- 情報欠損ぶん(原則6) ----
    // 速度が取れない相手は「止まっている」ではなく「上限まで動ける」。
    // 齢に比例させるので、鮮度が落ちるほど単調に広がる。
    final unknownSpeedGuard = (_isSpeedKnown(a) && _isSpeedKnown(b))
        ? 0.0
        : min(
            unknownSpeedMaxBoatSpeedMetersPerSecond * ageSeconds,
            maxUnknownSpeedGuardMeters,
          );
    final unknownHeadingGuard = (_isHeadingKnown(a) && _isHeadingKnown(b))
        ? 0.0
        : unknownHeadingGuardMeters;
    return ProtectionBudget(
      gnssMeasurementMeters: accuracyGuard,
      remoteLatencyMeters: extrapolationGuard,
      speedUnknownMeters: unknownSpeedGuard,
      headingUnknownMeters: unknownHeadingGuard,
    );
  }

  /// 2艇の中心間距離へ追加する安全マージン [m]。
  ///
  /// 内訳は [pairProtectionBudget] が持つ。ここはその相対合成値を返すだけ。
  ///
  /// **速度・方位が取れているときは従来と同じ値になる**(欠損ぶんが0のため)。
  /// 変わるのは欠損時だけで、そこは従来 0 として扱っていた分を足す。
  double pairGpsCenterDistanceGuardMeters(Boat a, Boat b, {DateTime? now}) =>
      pairProtectionBudget(a, b, now: now).relativeTotalMeters;

  double getStoppingDistance(Boat boat) {
    // 艇種ごとに停止距離を計算する(異常な速度は停止扱い)
    final speed = (boat.speed.isFinite && boat.speed > 0) ? boat.speed : 0.0;
    return boatConfigs.byBoatType(boat.boatType).stoppingDistanceFormula(speed);
  }

  double _validatedWarningTime(double? value) {
    if (value == null || !value.isFinite) return warningTime;
    return value.clamp(minWarningTimeSeconds, maxWarningTimeSeconds).toDouble();
  }

  Boat predictPosition(Boat boat, double afterSeconds) {
    final speed = boat.speed.isFinite ? boat.speed : 0.0;
    double distance = speed * afterSeconds;
    if (!distance.isFinite) distance = 0.0;
    final newLatLng =
        computeOffset(LatLng(boat.lat, boat.lng), distance, boat.heading);
    return boat.copyWithPosition(
      lat: newLatLng.latitude,
      lng: newLatLng.longitude,
      timestamp: boat.timestamp,
    );
  }

  /// 受信した艇情報を現在時刻まで推測航法で外挿する。
  /// 適応送信(5〜10秒間隔)で受信間隔が空いても、
  /// リスク評価と地図表示は最新の推定位置で行える。
  Boat extrapolateToNow(Boat boat, {DateTime? now}) {
    final now_ = now ?? DateTime.now();
    // observedAtは送信端末のwall clockなので、共有艇の外挿基準には
    // 補正済みserverUpdatedAtを優先する。自艇/旧データは従来値へfallback。
    final extrapolationTimestamp = boat.serverUpdatedAt ?? boat.timestamp;
    double dtSec =
        now_.difference(extrapolationTimestamp).inMilliseconds / 1000.0;
    if (dtSec <= 0) return boat;
    // 幽霊艇フィルタの上限を超える外挿はしない(安全側に倒す)
    if (dtSec > boatStaleTimeoutSeconds.toDouble()) {
      dtSec = boatStaleTimeoutSeconds.toDouble();
    }
    final predicted = predictPosition(boat, dtSec);
    return boat.copyWithPosition(
      lat: predicted.lat,
      lng: predicted.lng,
      timestamp: boat.timestamp,
    );
  }

  // 予測された状況を返す
  Situation predictSituation(Boat myBoat, List<Boat> otherBoats,
      List<StaticObstacle> obstacles, double afterSeconds) {
    Boat futureMyBoat = predictPosition(myBoat, afterSeconds);
    List<Boat> futureOtherBoats =
        otherBoats.map((boat) => predictPosition(boat, afterSeconds)).toList();
    final futureObstacles = obstacles;

    return Situation(
        myBoat: futureMyBoat,
        otherBoats: futureOtherBoats,
        obstacles: futureObstacles);
  }

  double _velocityEast(Boat boat) =>
      boat.speed * sin(degreesToRadians(boat.heading));

  double _velocityNorth(Boat boat) =>
      boat.speed * cos(degreesToRadians(boat.heading));

  ContinuousIntersection _withEntryDistance(
      ContinuousIntersection result, double speedMetersPerSecond) {
    final entry = result.firstEntryTimeSeconds;
    if (entry == null) return result;
    return result.copyWith(
      firstEntryDistanceMeters: max(0, speedMetersPerSecond) * entry,
    );
  }

  /// 静的区域に対し、予測終点ではなく予測区間全体を連続判定する。
  ///
  /// [centerline] があれば、予測経路を川なりの折れ線として掃引する。
  /// カーブで直線予測が外岸へ突っ込む誤警告と、曲がった先の見落としを防ぐ。
  /// 中心線が無ければ従来どおり等速直線1区間として扱う。
  ///
  /// [includeGpsGuard]がtrueの場合でも、旧アプリ由来の余裕入り
  /// 区域にGPS帯を二重追加しない。
  ///
  /// 掃引に使う領域は排他領域ではなく、kind別クリアランスの掃引領域
  /// ([ShipDomainService.getStaticSweepDomain])である。排他領域は
  /// 「他船に空けてほしい水面」であり、並走することが正常な岸へ当てると
  /// DESIGN_PRINCIPLES 1.4 と衝突する。前後方向は排他領域のままなので、
  /// 区域へ向かう艇の検知時刻は変わらない。
  ContinuousIntersection evaluateStaticContinuousIntersection(
    Boat myBoat,
    StaticObstacle obstacle, {
    required double horizonSeconds,
    bool includeGpsGuard = true,
    ChannelCenterline? centerline,
  }) {
    if (obstacle.points.length < 3) {
      return const ContinuousIntersection.none(
        reasonCodes: ['invalid_static_geometry'],
      );
    }
    final guard =
        includeGpsGuard ? staticGpsInflatePerSideMeters(myBoat, obstacle) : 0.0;
    final segments = _pathPredictor.predict(
      boat: myBoat,
      horizonSeconds: horizonSeconds,
      centerline: centerline,
    );
    var combined = const ContinuousIntersection.none();
    for (final segment in segments) {
      final segmentBoat = _boatOnSegment(myBoat, segment);
      final sweepDomain = _shipDomainService.getStaticSweepDomain(
        segmentBoat,
        clearancePerSideMeters: obstacle.kind.staticSweepClearanceMeters,
        lowSpeedLateralInflationFactor:
            obstacle.kind.staticSweepLowSpeedLateralInflationFactor,
        lateralInflateMeters: segment.curvatureMarginMeters,
      );
      final result = _continuousCollisionService.sweepAgainstStatic(
        movingPolygon: sweepDomain.points,
        staticPolygon: obstacle.points,
        origin: segment.origin,
        velocityEastMetersPerSecond: segment.velocityEastMetersPerSecond,
        velocityNorthMetersPerSecond: segment.velocityNorthMetersPerSecond,
        horizonSeconds: segment.durationSeconds,
        // GPS帯は全方向、折れ線の曲率残差は横方向だけへ分ける。
        inflateMeters: guard,
      );
      combined = _continuousCollisionService.combine(
        combined,
        _shiftIntersectionTime(result, segment.startTimeSeconds),
      );
    }
    return _withEntryDistance(combined, myBoat.speed);
  }

  /// 2艇の同期時刻の相対運動区間を連続判定する。
  ///
  /// 絶対座標上の航跡線が交差するかではなく、同じ将来時刻に
  /// `ownExclusive/otherBody`または逆組み合わせが重なるかを求める。
  /// 2艇のいずれかが低速で、進行方位を信頼できない状態か。
  ///
  /// この状態では船体・排他領域が横方向へ最大4m広がる。広げた分でしか
  /// 重ならない場合は「確実な衝突コース」ではないため、確度を下げて
  /// 提示を1バンド落とす(GPS帯だけで重なる場合と同じ扱い)。
  static bool boatPairHeadingIsUncertain(Boat a, Boat b) =>
      !ShipDomainService.headingIsReliable(a) ||
      !ShipDomainService.headingIsReliable(b);

  ContinuousIntersection evaluateBoatContinuousIntersection(
    Boat myBoat,
    Boat otherBoat, {
    required double horizonSeconds,
    bool includeGpsGuard = true,
    bool? headingReliable,
    ChannelCenterline? centerline,
    DateTime? now,
  }) {
    // 相対運動の直線掃引は川の湾曲を表現できない。両艇が川なりに曲がる分の
    // 経路ずれを、有界な横方向マージンとして領域へ加えて補う。
    final curvatureMargin = max(
      channelCurvatureMarginMeters(myBoat, horizonSeconds, centerline),
      channelCurvatureMarginMeters(otherBoat, horizonSeconds, centerline),
    );
    // 従来の相対掃引で1回だけ足していた曲率余裕を、両艇の横幅へ半分ずつ
    // 配る。合計の横方向余裕は保ちつつ、前後方向を伸ばさない。
    final lateralMarginPerDomain = curvatureMargin / 2;
    final myDomains = _shipDomainService.getShipDomains(
      myBoat,
      headingReliable: headingReliable,
      lateralInflateMeters: lateralMarginPerDomain,
    );
    final otherDomains = _shipDomainService.getShipDomains(
      otherBoat,
      headingReliable: headingReliable,
      lateralInflateMeters: lateralMarginPerDomain,
    );
    final relativeEast = _velocityEast(myBoat) - _velocityEast(otherBoat);
    final relativeNorth = _velocityNorth(myBoat) - _velocityNorth(otherBoat);
    final guard = includeGpsGuard
        ? pairGpsCenterDistanceGuardMeters(myBoat, otherBoat, now: now)
        : 0.0;
    final origin = LatLng(myBoat.lat, myBoat.lng);

    final ownExclusive = _continuousCollisionService.sweepRelative(
      movingPolygon: myDomains.exclusiveDomain.points,
      otherPolygon: otherDomains.shipBodyDomain.points,
      origin: origin,
      relativeVelocityEastMetersPerSecond: relativeEast,
      relativeVelocityNorthMetersPerSecond: relativeNorth,
      horizonSeconds: horizonSeconds,
      inflateMeters: guard,
    );
    final otherExclusive = _continuousCollisionService.sweepRelative(
      movingPolygon: myDomains.shipBodyDomain.points,
      otherPolygon: otherDomains.exclusiveDomain.points,
      origin: origin,
      relativeVelocityEastMetersPerSecond: relativeEast,
      relativeVelocityNorthMetersPerSecond: relativeNorth,
      horizonSeconds: horizonSeconds,
      inflateMeters: guard,
    );
    return _withEntryDistance(
      _continuousCollisionService.combine(ownExclusive, otherExclusive),
      myBoat.speed,
    );
  }

  // その状況で衝突が発生しているか判定を行う。
  // 衝突していれば脅威情報を、していなければnullを返す。
  //
  // 判定は2段階:
  // 1. 領域そのものの重なり → definite(確実な脅威)
  // 2. 位置不確実性マージン分拡張した領域の重なり → uncertain(不確実な脅威)
  // 幾何判定が例外を投げた場合は「脅威なし」に落とさず、
  // 外接円ベースの保守的な距離判定にフォールバックする(fail-safe)。
  ThreatInfo? findCollisionThreat(
      Boat myBoatRaw, List<Boat> otherBoats, List<StaticObstacle> obstacles,
      {DateTime? now}) {
    final myBoat = _usableBoat(myBoatRaw);
    if (myBoat == null) return null; // 自艇位置が不明(呼び出し側のGPS異常)
    final myDomains = _shipDomainService.getShipDomains(myBoat);
    final myCenter = LatLng(myBoat.lat, myBoat.lng);
    final myExclusiveRadius =
        ShipDomainService.effectiveExclusiveRadius(myBoat);

    ThreatInfo? uncertainThreat; // definiteが見つかればそちらを優先して返す
    ThreatInfo? definiteBridgeThreat;

    // ===========================
    // 障害物との衝突リスクを評価
    // ===========================
    for (final obstacle in obstacles) {
      if (!obstacle.isWarningEnabled) continue;
      if (obstacle.points.isEmpty) continue; // 位置情報が全くない区域は判定不能
      // カーブ／逆走注意は「区域に入ったこと」を知らせる案内区域であり、
      // 将来位置の衝突予測や15m近接注意の対象にはしない。
      if (obstacle.kind.isEntryGuidance) continue;
      ThreatInfo makeThreat(ThreatConfidence c) => ThreatInfo(
            kind: ThreatKind.obstacle,
            position: getMeanLatLng(obstacle.points),
            confidence: c,
            obstacleKind: obstacle.kind,
            obstacleId: obstacle.id,
            obstacleSourceId: obstacle.sourceId,
            obstacleBridgeId: obstacle.bridgeId,
            obstacleName: obstacle.name,
            warningAudioAsset: obstacle.warningAudioAsset,
            relativeBearingDegrees:
                _relativeBearingToObstacle(myBoat, obstacle),
          );
      bool geometryOk = false;
      final staticMargin = staticGpsInflatePerSideMeters(myBoat, obstacle);
      // 掃引側(assessRisk)と同じ kind 別クリアランスの領域を使う。
      // 旧経路だけ排他領域のままにすると、幾何例外時の退避や近接判定で
      // 岸の過剰警告が復活してしまう。
      final mySweepDomain = _shipDomainService.getStaticSweepDomain(
        myBoat,
        clearancePerSideMeters: obstacle.kind.staticSweepClearanceMeters,
        lowSpeedLateralInflationFactor:
            obstacle.kind.staticSweepLowSpeedLateralInflationFactor,
      );
      if (obstacle.points.length >= 3) {
        final obstacleDomain = Polygon(
          polygonId: PolygonId(obstacle.id),
          points: obstacle.points,
        );
        try {
          // 1. 確実な重なり(自艇の掃引領域 vs 障害物領域)
          if (polygonsOverlap(mySweepDomain, obstacleDomain)) {
            final threat = makeThreat(ThreatConfidence.definite);
            // 橋は通過対象なので保持しておき、他艇の確実な衝突を
            // 優先して確認する。
            if (obstacle.kind == StaticObstacleKind.bridge) {
              definiteBridgeThreat ??= threat;
            } else {
              return threat;
            }
          }
          // 2. 位置不確実性マージン込みの重なり
          final myInflatedSweepDomain = _shipDomainService.getStaticSweepDomain(
            myBoat,
            clearancePerSideMeters: obstacle.kind.staticSweepClearanceMeters,
            lowSpeedLateralInflationFactor:
                obstacle.kind.staticSweepLowSpeedLateralInflationFactor,
            inflateMeters: staticMargin,
          );
          if (polygonsOverlap(myInflatedSweepDomain, obstacleDomain)) {
            uncertainThreat ??= makeThreat(ThreatConfidence.uncertain);
          }
          geometryOk = true;
        } catch (e) {
          debugPrint('Obstacle geometry check failed. ID: ${obstacle.id} $e');
          // fail-silentにせず、下の距離ベース判定にフォールバックする
        }
      }
      if (!geometryOk) {
        // 頂点数不足・自己交差などでポリゴン判定ができない場合の
        // 保守的フォールバック: 外接円半径+マージン以内なら脅威とする。
        // 半径は掃引領域ではなく排他領域ベースのまま(保守側)にする。
        // ここは幾何判定が壊れたときの最後の砦なので、絞らない。
        final d = minDistanceToPolygonMeters(myCenter, obstacle.points);
        if (d <= myExclusiveRadius + staticMargin) {
          uncertainThreat ??= makeThreat(ThreatConfidence.uncertain);
        }
      }
    }

    // ===========================
    // 他艇との衝突リスクを評価
    // ===========================
    for (final otherBoatRaw in otherBoats) {
      final otherBoat = _usableBoat(otherBoatRaw);
      if (otherBoat == null) continue; // 位置が不明な艇は幾何判定不能
      ThreatInfo makeThreat(ThreatConfidence c) => ThreatInfo(
            kind: ThreatKind.boat,
            position: LatLng(otherBoat.lat, otherBoat.lng),
            confidence: c,
            boatId: otherBoat.boatId,
            boatSessionId: otherBoat.sessionId,
            relativeBearingDegrees: _relativeBearingTo(
              myBoat,
              LatLng(otherBoat.lat, otherBoat.lng),
            ),
          );
      final pairMargin =
          pairGpsCenterDistanceGuardMeters(myBoat, otherBoat, now: now);
      try {
        final otherDomains = _shipDomainService.getShipDomains(otherBoat);
        // 1. 確実な重なり(領域拡張なし)
        if (polygonsOverlap(
                myDomains.exclusiveDomain, otherDomains.shipBodyDomain) ||
            polygonsOverlap(
                otherDomains.exclusiveDomain, myDomains.shipBodyDomain)) {
          return makeThreat(ThreatConfidence.definite);
        }
        // 2. 合成不確実性マージン分、相手側の領域を拡張して判定
        final otherInflated = _shipDomainService.getShipDomains(otherBoat,
            inflateMeters: pairMargin);
        if (polygonsOverlap(
                myDomains.exclusiveDomain, otherInflated.shipBodyDomain) ||
            polygonsOverlap(
                otherInflated.exclusiveDomain, myDomains.shipBodyDomain)) {
          uncertainThreat ??= makeThreat(ThreatConfidence.uncertain);
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Boat geometry check failed. ID: ${otherBoat.boatId} $e');
        }
        // 保守的フォールバック: 外接円ベースの距離判定
        final otherParams = ShipDomainService.effectiveParamsFor(otherBoat);
        final d =
            distanceMeters(myCenter, LatLng(otherBoat.lat, otherBoat.lng));
        final r = myExclusiveRadius +
            ShipDomainService.boundingRadius(otherParams.shipBodyParam) +
            pairMargin;
        if (d <= r) {
          uncertainThreat ??= makeThreat(ThreatConfidence.uncertain);
        }
      }
    }
    return definiteBridgeThreat ?? uncertainThreat;
  }

  // その状況で衝突が発生しているか判定を行う(互換用)
  bool checkCollision(
      Boat myBoat, List<Boat> otherBoats, List<StaticObstacle> obstacles) {
    return findCollisionThreat(myBoat, otherBoats, obstacles) != null;
  }

  // 静的危険区域への近接リスクを評価する
  // 進行方向に関係なく、一定距離+位置不確実性マージン以内まで
  // 近づいたら注意(lv1)を返す。
  // 予測ベースの判定は進行方向上の衝突しか検知できないため、
  // 横向きの接近や漂流による接近の警告漏れを防ぐ目的で追加。
  RiskAssessment evaluateProximityRisk(
      Boat myBoatRaw, List<StaticObstacle> obstacles,
      {DateTime? now}) {
    final threats = findProximityThreats(myBoatRaw, obstacles, now: now);
    if (threats.isEmpty) {
      return RiskAssessment(level: CollisionRiskLevel.lv0);
    }
    return RiskAssessment(
      level: CollisionRiskLevel.lv1,
      primaryThreat: threats.first,
      threats: threats.map(
        (threat) => RiskThreat(level: CollisionRiskLevel.lv1, threat: threat),
      ),
    );
  }

  /// 岸と平行に航行しているだけで連続警告にならないよう、
  /// 「近い」に加えて「さらに接近中」または「すでに至近」を要求する。
  List<ThreatInfo> findProximityThreats(
      Boat myBoatRaw, List<StaticObstacle> obstacles,
      {DateTime? now}) {
    final myBoat = _usableBoat(myBoatRaw);
    if (myBoat == null) return const [];
    final myPosition = LatLng(myBoat.lat, myBoat.lng);
    final futureBoat =
        predictPosition(myBoat, proximityApproachLookaheadSeconds);
    final futurePosition = LatLng(futureBoat.lat, futureBoat.lng);
    final threats = <({double distance, ThreatInfo threat})>[];
    // 近接注意が届き得る最大半径。2秒先の予測位置ぶんも含めて索引を引く。
    final proximityReach = maxProximityCautionDistanceMeters +
        maxStaticGpsGuardFullWidthMeters +
        distanceMeters(myPosition, futurePosition);
    for (final obstacle in _indexFor(obstacles).query(
      myPosition,
      proximityReach,
    )) {
      if (!obstacle.isWarningEnabled) continue;
      if (obstacle.points.isEmpty) continue;
      if (obstacle.kind.isEntryGuidance) continue;
      final cautionDistance = obstacle.effectiveProximityCautionMeters;
      final guard = staticGpsInflatePerSideMeters(myBoat, obstacle);
      // 注意: 近接注意距離が0の区域でも早期continueしてはいけない。
      // 区域の内部(符号付き距離が負)は掃引判定の予備として必ず拾う。
      final distance =
          signedDistanceToPolygonMeters(myPosition, obstacle.points);
      final futureDistance =
          signedDistanceToPolygonMeters(futurePosition, obstacle.points);
      // 通常の操舵のふらつき(0.1m/s程度)で岸沿いに点滅しないよう、
      // 実際に寄っていく速度を要求する。
      final approaching =
          (distance - futureDistance) / proximityApproachLookaheadSeconds >=
              proximityApproachRateMetersPerSecond;
      final directionUnknown =
          myBoat.speed < proximityDirectionUnknownSpeedMetersPerSecond;
      final veryCloseDistance = max(2.0, cautionDistance * 0.35);
      final veryClose = distance <= veryCloseDistance + guard;
      if (distance > cautionDistance + guard ||
          (!approaching && !veryClose && !directionUnknown)) {
        continue;
      }
      threats.add((
        distance: distance,
        threat: ThreatInfo(
          kind: ThreatKind.obstacle,
          position: getMeanLatLng(obstacle.points),
          confidence: ThreatConfidence.definite,
          obstacleKind: obstacle.kind,
          obstacleId: obstacle.id,
          obstacleSourceId: obstacle.sourceId,
          obstacleBridgeId: obstacle.bridgeId,
          obstacleName: obstacle.name,
          warningAudioAsset: obstacle.warningAudioAsset,
          distanceMeters: distance,
          relativeBearingDegrees: _relativeBearingToObstacle(myBoat, obstacle),
        ),
      ));
    }
    threats.sort((a, b) => a.distance.compareTo(b.distance));
    return threats.map((item) => item.threat).toList(growable: false);
  }

  /// 航路レーンと中心線から、規定方向に対する逆走を判定する。
  ///
  /// 「区域内に現在地があるか」だけの判定では、1.2 の右側通行を守って
  /// 正しく漕いでいても区域を出入りするたびに鳴る(実機ログで77分に16回)。
  /// 原則4に反するため、その位置で進むべき向きと実際の進行方位を比べる。
  ///
  /// 明示的に紐付いたレーン・中心線が無い旧データでは、呼び出し側が
  /// 従来の逆走注意区域を使う。明示データがある場合、旧区域は無効化し、
  /// 確認済みの逆走だけを航路内の位置に関係なく候補化する。
  ///
  /// カーブ区域(`curve`)はこの判定の対象外。1カーブ1回で妥当に働いている。
  ReverseGuidanceOutcome evaluateReverseGuidance(
      Boat myBoat, ChannelCenterline? centerline,
      {ChannelLaneResolver? laneResolver}) {
    // ---- 縮退条件(原則1・原則3) ----
    // 方向が求まらない状況では従来の挙動を必ず残す。ここで compliant を
    // 返すと「中心線が無い水域では逆走注意が黙って消える」ことになる。
    if (!myBoat.lat.isFinite || !myBoat.lng.isFinite) {
      return ReverseGuidanceOutcome.unverified;
    }
    final position = LatLng(myBoat.lat, myBoat.lng);

    // 複数水域では、現在位置を含むレーンが明示参照する中心線だけを使う。
    // 距離が近い中心線を推測すると、霞ヶ浦と桜川の接続部などで規定方位が
    // 180度反転しうる。レーンの隙間・重なりは従来どおり判定保留にする。
    final usesLinkedCenterlines = laneResolver?.hasLinkedCenterlines ?? false;
    final matchedLane =
        usesLinkedCenterlines ? laneResolver!.resolveLane(position) : null;
    if (usesLinkedCenterlines && matchedLane == null) {
      return ReverseGuidanceOutcome.laneUndetermined;
    }
    final effectiveCenterline = usesLinkedCenterlines
        ? laneResolver!.centerlineFor(position)
        : centerline;
    if (effectiveCenterline == null) {
      return ReverseGuidanceOutcome.unverified;
    }

    final frame = effectiveCenterline.project(position);
    if (!frame.isInsideCoverage) return ReverseGuidanceOutcome.unverified;
    if (!frame.crossMeters.isFinite ||
        frame.crossMeters.abs() > maxChannelProjectionOffsetMeters) {
      return ReverseGuidanceOutcome.unverified;
    }
    final tangent = effectiveCenterline.tangentBearingAt(frame.alongMeters);
    if (!tangent.isFinite) return ReverseGuidanceOutcome.unverified;

    // ---- 入力が意味を持たない場合は助言しない ----
    // 停止・回頭中(< 0.5m/s)の保持方位は実際の艇の向きと最大90度ずれる
    // (不変条件10と同じ理由)。折り返しのたびに逆走と言われるのを防ぐ。
    // これは「データ欠損を安全の根拠にする」(原則6違反)のではなく、
    // 意味を持たない入力から助言を作らない、という判断である。
    // 上の縮退条件を先に通しているので、中心線が無い水域では従来どおり
    // 区域内で発報し続ける。
    if (!myBoat.heading.isFinite ||
        !ShipDomainService.headingIsReliable(myBoat)) {
      return ReverseGuidanceOutcome.compliant;
    }
    // ---- 明示レーンを優先する ----
    // 2枚以上の有効なレーンがあるときは、中心線からの横断距離の符号を
    // レーン決定に使わない。境界の隙間や重なりは誤った180度反転ではなく
    // 「判定しない」にする。
    final hasCompleteLaneSet = laneResolver?.hasCompleteLaneSet ?? false;
    final laneDirection = usesLinkedCenterlines
        ? matchedLane!.direction
        : hasCompleteLaneSet
            ? laneResolver!.resolve(position)
            : null;
    if (hasCompleteLaneSet && laneDirection == null) {
      return ReverseGuidanceOutcome.laneUndetermined;
    }

    if (laneDirection != null) {
      final requiredBearing =
          laneDirection == LaneDirection.along ? tangent : tangent + 180.0;
      final error =
          relativeBearingDegrees(myBoat.heading, requiredBearing).abs();
      return error >= reverseGuidanceHeadingErrorDegrees
          ? ReverseGuidanceOutcome.reverse
          : ReverseGuidanceOutcome.compliant;
    }

    // ---- 後方互換の縮退経路 ----
    // レーンが1枚以下/未設定なら、従来の cross 符号方式を残す。
    // 中心線の直上はどちらのレーンとも言い切れない。GPS誤差で cross の符号が
    // 反転すると規定方位が180度ひっくり返り、正常な艇を逆走と誤判定する。
    if (frame.crossMeters.abs() <= reverseGuidanceLaneAmbiguityMeters) {
      return ReverseGuidanceOutcome.compliant;
    }

    // `ChannelFrame.crossMeters` は「接線方位から見て右が正」
    // (channel_centerline.dart の project / toLatLng が共有する符号規約)。
    // 右側通行なので、接線方位 T の向きで進む艇は T の右手側(cross > 0)に
    // いるはずである。自艇が左手側(cross < 0)にいるなら、その位置で
    // 進むべき向きは逆向きの T+180 になる。
    final requiredBearing = frame.crossMeters > 0 ? tangent : tangent + 180.0;
    final error = relativeBearingDegrees(myBoat.heading, requiredBearing).abs();
    return error >= reverseGuidanceHeadingErrorDegrees
        ? ReverseGuidanceOutcome.reverse
        : ReverseGuidanceOutcome.compliant;
  }

  /// カーブ／逆走注意区域は、現在位置がポリゴン内に入ったときだけ
  /// 注意を出す。進行方向の予測や区域外の近接では鳴らさない。
  RiskAssessment evaluateEntryGuidanceRisk(
      Boat myBoatRaw, List<StaticObstacle> obstacles) {
    final myBoat = _usableBoat(myBoatRaw);
    if (myBoat == null) return RiskAssessment(level: CollisionRiskLevel.lv0);
    final myPosition = LatLng(myBoat.lat, myBoat.lng);
    for (final obstacle in obstacles) {
      if (!obstacle.isWarningEnabled) continue;
      if (!obstacle.kind.isEntryGuidance || obstacle.points.length < 3) {
        continue;
      }
      if (isPointInPolygon(myPosition, obstacle.points)) {
        return RiskAssessment(
          level: CollisionRiskLevel.lv1,
          primaryThreat: ThreatInfo(
            kind: ThreatKind.obstacle,
            position: getMeanLatLng(obstacle.points),
            confidence: ThreatConfidence.definite,
            obstacleKind: obstacle.kind,
            obstacleId: obstacle.id,
            obstacleSourceId: obstacle.sourceId,
            obstacleBridgeId: obstacle.bridgeId,
            obstacleName: obstacle.name,
            warningAudioAsset: obstacle.warningAudioAsset,
            relativeBearingDegrees:
                _relativeBearingToObstacle(myBoat, obstacle),
          ),
        );
      }
    }
    return RiskAssessment(level: CollisionRiskLevel.lv0);
  }

  /// 将来の衝突リスクを評価し、リスクレベルと脅威情報を返す。
  ///
  /// レベルの決め方:
  /// - 自艇の停止距離内で確実な衝突 → lv3(緊急)
  /// - 同・不確実(GPS誤差マージン込みでのみ衝突) → lv2
  /// - 警告距離内で確実な衝突 → lv2 / 不確実 → lv1
  /// - 他艇起因(相手の停止距離内) → 確実lv2 / 不確実lv1
  /// - 危険区域への近接 → lv1
  /// 「確実」は領域そのものの重なり。「不確実」を1段下げるのは、
  /// GPS誤差マージンによる誤報で緊急警報の信頼性を損なわないため。
  RiskAssessment assessRisk(
    Boat myBoatRaw,
    List<Boat> otherBoatsRaw,
    List<StaticObstacle> obstacles, {
    double? warningTimeSeconds,
    ChannelCenterline? centerline,
    ChannelLaneResolver? laneResolver,
    BoundedPositionSet? ownPositionSet,
  }) {
    final now = DateTime.now();
    final configuredWarningTime = _validatedWarningTime(warningTimeSeconds);
    CollisionRiskLevel level = CollisionRiskLevel.lv0;
    ThreatInfo? primaryThreat;
    final detectedThreats = <RiskThreat>[];

    void raiseLevel(CollisionRiskLevel newLevel, ThreatInfo? threat) {
      if (newLevel != CollisionRiskLevel.lv0 && threat != null) {
        detectedThreats.add(RiskThreat(level: newLevel, threat: threat));
      }
      final newIntersection = threat?.continuousIntersection;
      final currentIntersection = primaryThreat?.continuousIntersection;
      final sameLevelButMoreUrgent = newLevel.index == level.index &&
          newIntersection != null &&
          (currentIntersection == null ||
              (newIntersection.currentOverlap &&
                  !currentIntersection.currentOverlap) ||
              ((newIntersection.firstEntryTimeSeconds ?? double.infinity) <
                  (currentIntersection.firstEntryTimeSeconds ??
                      double.infinity)));
      if (newLevel.index > level.index || sameLevelButMoreUrgent) {
        level = newLevel;
        primaryThreat = threat ?? primaryThreat;
      }
    }

    // 異常値の正規化(1艇の異常データで評価全体が壊れないように)
    final myBoat = _usableBoat(myBoatRaw);
    if (myBoat == null) {
      // 自艇のGPSが完全に異常な場合は評価不能。
      // 呼び出し側(useNavigator)は正常なPositionのみ渡してくる想定。
      return RiskAssessment(level: CollisionRiskLevel.lv0);
    }
    final otherBoats =
        otherBoatsRaw.map(_usableBoat).whereType<Boat>().toList();

    // カーブは現在地を含む区域、逆走は下で新旧方式を切り替えて候補化する。
    final myPosition = LatLng(myBoat.lat, myBoat.lng);
    // 逆走判定だけでなく、岸・橋・他艇への将来経路も同じ水域の中心線へ
    // 揃える。複数中心線時の全体フォールバックはnullなので、レーン外では
    // 安全に従来の直線予測へ縮退する。
    final effectiveCenterline =
        laneResolver?.centerlineFor(myPosition) ?? centerline;
    final obstacleIndex = _indexFor(obstacles);
    final usesLinkedReverseGuidance =
        laneResolver?.hasLinkedCenterlines ?? false;

    // 明示レーン＋中心線が登録済みなら、旧「逆走注意エリア」をトリガーに
    // せず、レーン全域で確認済みの逆走だけを候補化する。
    //
    // obstacleKindをreverseに保つことで、表示名・標準音声
    // (audio/reverse_warning.mp3)・6秒音声確定・再武装は既存経路を流用する。
    if (usesLinkedReverseGuidance) {
      final outcome = evaluateReverseGuidance(
        myBoat,
        effectiveCenterline,
        laneResolver: laneResolver,
      );
      if (outcome == ReverseGuidanceOutcome.reverse) {
        final lane = laneResolver!.resolveLane(myPosition)!;
        raiseLevel(
          CollisionRiskLevel.lv1,
          ThreatInfo(
            kind: ThreatKind.obstacle,
            position: myPosition,
            confidence: ThreatConfidence.definite,
            obstacleKind: StaticObstacleKind.reverse,
            obstacleId: 'channel_reverse_${lane.id}',
            obstacleSourceId: 'channel_reverse_${lane.id}',
            obstacleName: '${lane.name} 逆走注意',
            continuousIntersection: const ContinuousIntersection(
              intersects: true,
              currentOverlap: true,
              firstEntryTimeSeconds: null,
              firstExitTimeSeconds: null,
              minimumSeparationMeters: 0,
              confidence: 1.0,
              reasonCodes: [
                'reverse_direction_confirmed',
                'linked_centerline_guidance',
              ],
            ),
          ),
        );
      }
    }

    // 逆走の方向判定は区域ごとに変わらないので、区域ループの外で1度だけ求める。
    ReverseGuidanceOutcome? reverseOutcome;
    // 現在地を含むかどうかだけなので、索引は半径0で引けばよい。
    for (final obstacle in obstacleIndex.query(myPosition, 0)) {
      if (!obstacle.isWarningEnabled) continue;
      if (!obstacle.kind.isEntryGuidance || obstacle.points.length < 3) {
        continue;
      }
      if (!isPointInPolygon(myPosition, obstacle.points)) continue;
      // 逆走区域だけは進行方向も見る。カーブは従来どおり進入で1回。
      ContinuousIntersection? guidanceIntersection;
      if (obstacle.kind == StaticObstacleKind.reverse) {
        // 明示レーン＋中心線方式では上で全航路を判定済み。旧区域を二重に
        // 評価すると、区域境界で別の警告エピソードが発生するため無効化する。
        if (usesLinkedReverseGuidance) continue;
        final outcome = reverseOutcome ??= evaluateReverseGuidance(
          myBoat,
          effectiveCenterline,
          laneResolver: laneResolver,
        );
        if (outcome == ReverseGuidanceOutcome.compliant ||
            outcome == ReverseGuidanceOutcome.laneUndetermined) {
          continue;
        }
        // ThreatInfo に理由コード専用のフィールドは無いため、
        // 既存の仕組み(SafetyOrchestrator が
        // `continuousIntersection.reasonCodes` をそのまま
        // AlertCandidate へ渡す)に載せる。currentOverlap と
        // firstEntryTimeSeconds は、区域進入イベントとしての従来の扱い
        // (`currentOverlap: ... ?? kind.isEntryGuidance`、deadline なし)を
        // そのまま再現する値にしてある。提示の挙動は変えず、理由だけ足す。
        guidanceIntersection = ContinuousIntersection(
          intersects: true,
          currentOverlap: true,
          firstEntryTimeSeconds: null,
          firstExitTimeSeconds: null,
          minimumSeparationMeters: 0,
          confidence: outcome == ReverseGuidanceOutcome.reverse ? 1.0 : 0.5,
          reasonCodes: [
            outcome == ReverseGuidanceOutcome.reverse
                ? 'reverse_direction_confirmed'
                : 'reverse_direction_unverified',
          ],
        );
      }
      raiseLevel(
        CollisionRiskLevel.lv1,
        ThreatInfo(
          kind: ThreatKind.obstacle,
          position: getMeanLatLng(obstacle.points),
          confidence: ThreatConfidence.definite,
          obstacleKind: obstacle.kind,
          obstacleId: obstacle.id,
          obstacleSourceId: obstacle.sourceId,
          obstacleBridgeId: obstacle.bridgeId,
          obstacleName: obstacle.name,
          warningAudioAsset: obstacle.warningAudioAsset,
          relativeBearingDegrees: _relativeBearingToObstacle(myBoat, obstacle),
          continuousIntersection: guidanceIntersection,
        ),
      );
    }

    final ownStoppingDistance = getStoppingDistance(myBoat);
    final ownStoppingTime =
        myBoat.speed > 0 ? ownStoppingDistance / myBoat.speed : 0.0;
    final staticHorizon = max(configuredWarningTime, ownStoppingTime);
    // 低速時の横方向拡張を含む実効半径を使う。生のパラメータで到達距離を
    // 見積もると、拡張した領域が触れる区域を broad-phase で捨ててしまう。
    final myCenter = LatLng(myBoat.lat, myBoat.lng);
    final ownSetRadius = ownPositionSet?.boundingRadiusMeters ?? 0;
    final myDomainRadius = ShipDomainService.effectiveExclusiveRadius(
      myBoat,
      positionSetBoundingRadiusMeters: ownSetRadius,
    );

    // 静的区域: 自艇の掃引領域(kind別クリアランス)を予測線分に沿って掃引する。
    // 予測が届き得る最大半径で索引を引き、無関係な区域のポリゴン距離計算
    // (岸だけで300枚超)を最初から避ける。
    //
    // 到達半径は掃引領域ではなく排他領域ベース([myDomainRadius])のまま。
    // 掃引領域は排他領域より広くならない(不変条件8・staticSweepParam の
    // 横幅は排他領域で頭打ち)ので、これは常に保守側であり、
    // narrow-phase で重なる候補を取りこぼさない。
    final staticReach = myBoat.speed * staticHorizon +
        myDomainRadius +
        maxStaticGpsGuardFullWidthMeters +
        maxChannelCurvatureMarginMeters;
    for (final obstacle in obstacleIndex.query(myCenter, staticReach)) {
      if (!obstacle.isWarningEnabled) continue;
      if (obstacle.kind.isEntryGuidance || obstacle.points.isEmpty) continue;
      // 予測時間内の最大移動距離にも届かない区域は、
      // 結果を変えずに高価な三角形分割/SATを省略できる。
      // ここも半径は排他領域ベースのまま(掃引領域はこれを超えない)。
      final broadPhaseDistance =
          minDistanceToPolygonMeters(myCenter, obstacle.points);
      final broadPhaseReach = myBoat.speed * staticHorizon +
          myDomainRadius +
          staticGpsInflatePerSideMeters(myBoat, obstacle) +
          maxChannelCurvatureMarginMeters;
      if (broadPhaseDistance > broadPhaseReach) continue;
      ContinuousIntersection? intersection;
      ThreatConfidence confidence = ThreatConfidence.definite;
      // 重ならない場合でも、最接近距離(DCPA相当)は記録・表示に使う。
      double? separationMeters;
      try {
        // S2では自艇だけ、代表点とは別の到達集合を初期形状へ加える。
        // 集合でのみ触れる場合は「可能性」であり、確実衝突へは上げない。
        final setTouchesNow =
            ownPositionSet?.intersectsPolygon(obstacle.points) ?? false;
        final definite = setTouchesNow
            ? const ContinuousIntersection(
                intersects: true,
                currentOverlap: true,
                firstEntryTimeSeconds: 0,
                firstExitTimeSeconds: 0,
                firstEntryDistanceMeters: 0,
                minimumSeparationMeters: 0,
                confidence: 0.7,
                reasonCodes: ['own_position_set_entry'],
              )
            : evaluateStaticContinuousIntersection(
                myBoat,
                obstacle,
                horizonSeconds: staticHorizon,
                includeGpsGuard: false,
                centerline: effectiveCenterline,
              );
        separationMeters = definite.minimumSeparationMeters;
        if (definite.intersects) {
          if (setTouchesNow) confidence = ThreatConfidence.uncertain;
          intersection = definite;
        } else {
          final guarded = evaluateStaticContinuousIntersection(
            myBoat,
            obstacle,
            horizonSeconds: staticHorizon,
            centerline: effectiveCenterline,
          );
          if (guarded.intersects) {
            confidence = ThreatConfidence.uncertain;
            intersection = guarded.copyWith(
              currentOverlap: false,
              confidence: 0.7,
              reasonCodes: {
                ...guarded.reasonCodes,
                'gps_guard_entry',
              }.toList(),
            );
          }
        }
      } catch (error) {
        // 不正ポリゴンは現行の保守的距離判定へ退避し、
        // 幾何例外で評価全体を止めない。
        final fallback =
            findCollisionThreat(myBoat, const [], [obstacle], now: now);
        if (fallback != null) {
          confidence = ThreatConfidence.uncertain;
          intersection = const ContinuousIntersection(
            intersects: true,
            currentOverlap: true,
            firstEntryTimeSeconds: 0,
            firstExitTimeSeconds: 0,
            firstEntryDistanceMeters: 0,
            minimumSeparationMeters: 0,
            confidence: 0.4,
            reasonCodes: ['invalid_geometry_fallback'],
          );
        }
      }
      if (intersection == null) continue;

      final entryDistance = intersection.firstEntryDistanceMeters ?? 0;
      final withinStoppingDistance = intersection.currentOverlap ||
          (myBoat.speed > 0 && entryDistance <= ownStoppingDistance);
      final obstaclePosition = getMeanLatLng(obstacle.points);
      final threat = ThreatInfo(
        kind: ThreatKind.obstacle,
        position: obstaclePosition,
        confidence: confidence,
        obstacleKind: obstacle.kind,
        obstacleId: obstacle.id,
        obstacleSourceId: obstacle.sourceId,
        obstacleBridgeId: obstacle.bridgeId,
        obstacleName: obstacle.name,
        warningAudioAsset: obstacle.warningAudioAsset,
        // 区域の重心ではなく最寄りの辺までの符号付き距離を使う。岸の危険区域は
        // 基準線の各辺を長方形にしたものなので、重心距離は「岸にどれだけ近いか」
        // とほぼ無関係で、安定停止中の再接近検出が誤作動する。
        distanceMeters:
            signedDistanceToPolygonMeters(myCenter, obstacle.points),
        relativeBearingDegrees: _relativeBearingToObstacle(myBoat, obstacle),
        separationMeters: intersection.intersects ? 0 : separationMeters,
        continuousIntersection: intersection,
      );
      final candidateLevel = withinStoppingDistance
          ? (confidence == ThreatConfidence.definite
              ? CollisionRiskLevel.lv3
              : CollisionRiskLevel.lv2)
          : (confidence == ThreatConfidence.definite
              ? CollisionRiskLevel.lv2
              : CollisionRiskLevel.lv1);
      raiseLevel(candidateLevel, threat);
    }

    // 他艇: 同期時刻の相対運動線分と合成安全領域を連続判定する。
    for (final otherBoat in otherBoats) {
      final otherSpeed = otherBoat.speed;
      final otherStoppingDistance = getStoppingDistance(otherBoat);
      final otherStoppingTime =
          otherSpeed > 0 ? otherStoppingDistance / otherSpeed : 0.0;
      final horizon = max(
        configuredWarningTime,
        max(ownStoppingTime, otherStoppingTime),
      );
      final otherDomainRadius =
          ShipDomainService.effectiveExclusiveRadius(otherBoat);
      final centerDistance = distanceMeters(
        myCenter,
        LatLng(otherBoat.lat, otherBoat.lng),
      );
      // 掃引側は inflateMeters に pair guard と曲率マージンの両方を渡す
      // (evaluateBoatContinuousIntersection)。到達距離の見積りが曲率マージンを
      // 含まないと、narrow-phase なら重なる候補を最大3m ぶん取りこぼす。
      // 静的区域側(staticReach)と同じく上界を必ず含めること。
      final relativeReach = (myBoat.speed + otherSpeed) * horizon +
          myDomainRadius +
          otherDomainRadius +
          pairGpsCenterDistanceGuardMeters(myBoat, otherBoat, now: now) +
          maxChannelCurvatureMarginMeters;
      if (centerDistance > relativeReach) continue;
      ContinuousIntersection? intersection;
      ThreatConfidence confidence = ThreatConfidence.definite;
      // 重ならない場合の最接近距離(DCPA相当)。すれ違いの余裕として
      // 記録し、近すぎるすれ違いは注意(lv1)の根拠にする。
      double? separationMeters;
      // 折り返しの回頭中などは方位が信頼できず、領域が横へ最大4m広がる。
      // その拡張ぶんでしか重ならない場合まで「確実(=連続音)」にすると、
      // 回頭のたびに通過艇へ連続音が鳴って警告が形骸化する。
      // 拡張なしの形状で判定し直し、そちらで重ならなければ確度を下げる。
      final headingUncertain = boatPairHeadingIsUncertain(myBoat, otherBoat);
      try {
        final definite = evaluateBoatContinuousIntersection(
          myBoat,
          otherBoat,
          horizonSeconds: horizon,
          includeGpsGuard: false,
          headingReliable: headingUncertain ? true : null,
          centerline: effectiveCenterline,
          now: now,
        );
        separationMeters = definite.minimumSeparationMeters;
        if (definite.intersects) {
          intersection = definite;
        } else {
          if (headingUncertain) {
            // 低速拡張を含む実際の形状。重なれば検知は残しつつ1段下げる。
            final widened = evaluateBoatContinuousIntersection(
              myBoat,
              otherBoat,
              horizonSeconds: horizon,
              includeGpsGuard: false,
              centerline: effectiveCenterline,
              now: now,
            );
            separationMeters =
                min(separationMeters, widened.minimumSeparationMeters);
            if (widened.intersects) {
              confidence = ThreatConfidence.uncertain;
              intersection = widened.copyWith(
                currentOverlap: false,
                confidence: 0.7,
                reasonCodes: {
                  ...widened.reasonCodes,
                  'heading_uncertainty_entry',
                }.toList(),
              );
            }
          }
          if (intersection == null) {
            final guarded = evaluateBoatContinuousIntersection(
              myBoat,
              otherBoat,
              horizonSeconds: horizon,
              centerline: effectiveCenterline,
              now: now,
            );
            // GPS帯込みのほうが隙間は狭く出る。近接注意には保守的な側を使う。
            separationMeters =
                min(separationMeters, guarded.minimumSeparationMeters);
            if (guarded.intersects) {
              confidence = ThreatConfidence.uncertain;
              intersection = guarded.copyWith(
                currentOverlap: false,
                confidence: 0.7,
                reasonCodes: {
                  ...guarded.reasonCodes,
                  'gps_guard_entry',
                }.toList(),
              );
            }
          }
        }
      } catch (error) {
        // 艇領域は通常は常に凸六角形。予期せぬ数値例外時のみ
        // 現在時刻の従来判定へ退避する。
        final fallback =
            findCollisionThreat(myBoat, [otherBoat], const [], now: now);
        if (fallback != null) {
          confidence = fallback.confidence;
          intersection = const ContinuousIntersection(
            intersects: true,
            currentOverlap: true,
            firstEntryTimeSeconds: 0,
            firstExitTimeSeconds: 0,
            firstEntryDistanceMeters: 0,
            minimumSeparationMeters: 0,
            confidence: 0.4,
            reasonCodes: ['geometry_fallback'],
          );
        }
      }
      if (intersection == null) {
        // 領域は重ならないが、すれ違いの隙間が極端に狭い場合は注意にする。
        // 二値の重なり判定だけでは「ぎりぎり当たらない」接近を拾えない。
        final separation = separationMeters;
        if (separation != null &&
            separation.isFinite &&
            separation <= nearMissSeparationMeters &&
            (myBoat.speed > 0 || otherSpeed > 0)) {
          raiseLevel(
            CollisionRiskLevel.lv1,
            ThreatInfo(
              kind: ThreatKind.boat,
              position: LatLng(otherBoat.lat, otherBoat.lng),
              confidence: ThreatConfidence.uncertain,
              boatId: otherBoat.boatId,
              boatSessionId: otherBoat.sessionId,
              distanceMeters: centerDistance,
              relativeBearingDegrees: _relativeBearingTo(
                myBoat,
                LatLng(otherBoat.lat, otherBoat.lng),
              ),
              separationMeters: separation,
              continuousIntersection: ContinuousIntersection(
                intersects: false,
                currentOverlap: false,
                firstEntryTimeSeconds: null,
                firstExitTimeSeconds: null,
                minimumSeparationMeters: separation,
                confidence: 0.5,
                reasonCodes: const ['near_miss_separation'],
              ),
            ),
          );
        }
        continue;
      }

      final entryTime = intersection.firstEntryTimeSeconds ?? 0;
      final ownDistance = myBoat.speed * entryTime;
      final otherDistance = otherSpeed * entryTime;
      final ownWithinStoppingDistance = intersection.currentOverlap ||
          (myBoat.speed > 0 && ownDistance <= ownStoppingDistance);
      final otherWithinStoppingDistance = intersection.currentOverlap ||
          (otherSpeed > 0 && otherDistance <= otherStoppingDistance);

      var candidateLevel = CollisionRiskLevel.lv1;
      if (confidence == ThreatConfidence.definite) {
        if (ownWithinStoppingDistance) {
          candidateLevel = CollisionRiskLevel.lv3;
        } else if (otherWithinStoppingDistance) {
          candidateLevel = CollisionRiskLevel.lv2;
        } else {
          candidateLevel = CollisionRiskLevel.lv2;
        }
      } else if (ownWithinStoppingDistance) {
        candidateLevel = CollisionRiskLevel.lv2;
      }
      raiseLevel(
        candidateLevel,
        ThreatInfo(
          kind: ThreatKind.boat,
          position: LatLng(otherBoat.lat, otherBoat.lng),
          confidence: confidence,
          boatId: otherBoat.boatId,
          boatSessionId: otherBoat.sessionId,
          distanceMeters: centerDistance,
          relativeBearingDegrees: _relativeBearingTo(
            myBoat,
            LatLng(otherBoat.lat, otherBoat.lng),
          ),
          separationMeters: 0,
          continuousIntersection: intersection,
        ),
      );
    }

    // 静的危険区域への近接リスクを評価(注意レベルの下限を保証)
    for (final threat in findProximityThreats(myBoat, obstacles, now: now)) {
      raiseLevel(CollisionRiskLevel.lv1, threat);
    }

    return RiskAssessment(
      level: level,
      primaryThreat: primaryThreat,
      threats: detectedThreats,
    );
  }

  // その状況の将来の衝突リスクを評価する(互換用・レベルのみ返す)
  CollisionRiskLevel evaluateFutureRisk(
      Boat myBoat, List<Boat> otherBoats, List<StaticObstacle> obstacles,
      {double? warningTimeSeconds}) {
    return assessRisk(myBoat, otherBoats, obstacles,
            warningTimeSeconds: warningTimeSeconds)
        .level;
  }
}
