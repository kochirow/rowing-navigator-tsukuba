import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../config/risk_evaluator_config.dart';
import '../models/boat_model.dart';
import '../models/static_obstacle_model.dart';
import '../theme/map_layer_spec.dart';
import '../utils/geo_math.dart';
import 'channel_centerline.dart';
import 'channel_path_predictor.dart';
import 'collision_risk_evaluator_service.dart';
import 'ship_domain_service.dart';

/// 開発時だけ地図に重ねる、静的危険区域の判定形状を作る。
///
/// 通常の地図表示はこのサービスを呼ばない。不変条件6（通常表示へ判定専用の
/// 拡張を反映しない）を守るため、ここで生成する Polygon は開発者トグルが
/// 有効なときだけ別レイヤーに加える。
class SafetyShapeOverlayService {
  SafetyShapeOverlayService({
    ShipDomainService? shipDomainService,
    CollisionRiskEvaluatorService? riskEvaluatorService,
    ChannelPathPredictor? pathPredictor,
  })  : _shipDomainService = shipDomainService ?? ShipDomainService(),
        _riskEvaluatorService =
            riskEvaluatorService ?? CollisionRiskEvaluatorService(),
        _pathPredictor = pathPredictor ?? const ChannelPathPredictor();

  final ShipDomainService _shipDomainService;
  final CollisionRiskEvaluatorService _riskEvaluatorService;
  final ChannelPathPredictor _pathPredictor;

  /// 艇の実体、現在位置の静的掃引枠、予測地平までの掃引帯を返す。
  ///
  /// 静的掃引枠・掃引帯は、警告対象になっている静的区域の kind ごとに作る。
  /// kind ごとに clearance と低速時の横拡張係数が異なるため、1つに丸めると
  /// 「今どの形で判定しているか」を確認できなくなる。
  Set<Polygon> build({
    required Boat boat,
    required Iterable<StaticObstacle> obstacles,
    required double warningTimeSeconds,
    ChannelCenterline? centerline,
  }) {
    if (!_isUsableBoat(boat)) return const <Polygon>{};

    final overlay = <Polygon>{};
    final body = _shipDomainService
        .getShipDomains(
          boat,
          // 艇の実体は方位不確かさによる判定用の幅を含めない。
          headingReliable: true,
        )
        .shipBodyDomain;
    overlay.add(Polygon(
      polygonId: PolygonId('developer_shape_ship_body_${boat.boatId}'),
      points: body.points,
      strokeWidth: 3,
      strokeColor: const Color(0xFF212121),
      fillColor: Colors.transparent,
      zIndex: developerOverlayZIndex,
    ));

    final kinds = <StaticObstacleKind>{
      for (final obstacle in obstacles)
        if (obstacle.isWarningEnabled && !obstacle.kind.isEntryGuidance)
          obstacle.kind,
    };
    if (kinds.isEmpty) return overlay;

    final horizon = _staticHorizonSeconds(boat, warningTimeSeconds);
    final representativeByKind = <StaticObstacleKind, StaticObstacle>{
      for (final obstacle in obstacles)
        if (obstacle.isWarningEnabled && !obstacle.kind.isEntryGuidance)
          obstacle.kind: obstacle,
    };
    final segments = _pathPredictor.predict(
      boat: boat,
      horizonSeconds: horizon,
      centerline: centerline,
    );

    for (final kind in kinds) {
      final obstacle = representativeByKind[kind]!;
      final guard =
          _riskEvaluatorService.staticGpsInflatePerSideMeters(boat, obstacle);
      final currentSweep = _effectiveSweepDomain(
        boat,
        kind: kind,
        gpsGuardMeters: guard,
      );
      overlay.add(Polygon(
        polygonId: PolygonId(
          'developer_shape_static_sweep_now_${boat.boatId}_${kind.name}',
        ),
        points: currentSweep.points,
        strokeWidth: 2,
        strokeColor: const Color(0xFF00695C),
        fillColor: Colors.transparent,
        zIndex: developerOverlayZIndex - 1,
      ));

      for (var index = 0; index < segments.length; index++) {
        final segment = segments[index];
        final segmentBoat = _boatOnSegment(boat, segment);
        final start = _effectiveSweepDomain(
          segmentBoat,
          kind: kind,
          gpsGuardMeters: guard,
          curvatureMarginMeters: segment.curvatureMarginMeters,
        );
        final end = _sweepAtSegmentEnd(
          segmentBoat,
          segment,
          kind: kind,
          gpsGuardMeters: guard,
        );
        final sweptHull = _convexHull([
          ...start.points,
          ...end.points,
        ]);
        if (sweptHull.length < 3) continue;
        // 塗りは実在する危険区域だけに使う既存規則を守る。ここは将来の
        // 判定域なので、実線ではなく輪郭線だけにする。
        overlay.add(Polygon(
          polygonId: PolygonId(
            'developer_shape_prediction_${boat.boatId}_${kind.name}_$index',
          ),
          points: sweptHull,
          strokeWidth: 2,
          strokeColor: const Color(0xFF1565C0),
          fillColor: Colors.transparent,
          zIndex: developerOverlayZIndex - 2,
        ));
      }
    }
    return overlay;
  }

  Polygon _effectiveSweepDomain(
    Boat boat, {
    required StaticObstacleKind kind,
    required double gpsGuardMeters,
    double curvatureMarginMeters = 0,
  }) =>
      _shipDomainService.getStaticSweepDomain(
        boat,
        clearancePerSideMeters: kind.staticSweepClearanceMeters,
        lowSpeedLateralInflationFactor:
            kind.staticSweepLowSpeedLateralInflationFactor,
        // 判定本体では GPS 帯を静的区域側へ加える。表示では同じ幅を
        // 掃引形状へ加えて、現在使っている実効的な余裕を目で確認できる。
        inflateMeters: gpsGuardMeters,
        lateralInflateMeters: curvatureMarginMeters,
      );

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

  Polygon _sweepAtSegmentEnd(
    Boat boat,
    PredictedMotionSegment segment, {
    required StaticObstacleKind kind,
    required double gpsGuardMeters,
  }) {
    final end = computeOffset(
      LatLng(boat.lat, boat.lng),
      segment.lengthMeters,
      segment.headingDegrees,
    );
    return _effectiveSweepDomain(
      boat.copyWithPosition(lat: end.latitude, lng: end.longitude),
      kind: kind,
      gpsGuardMeters: gpsGuardMeters,
      curvatureMarginMeters: segment.curvatureMarginMeters,
    );
  }

  double _staticHorizonSeconds(Boat boat, double warningTimeSeconds) {
    final warning = warningTimeSeconds.isFinite
        ? warningTimeSeconds
            .clamp(minWarningTimeSeconds, maxWarningTimeSeconds)
            .toDouble()
        : warningTime;
    final stoppingDistance = _riskEvaluatorService.getStoppingDistance(boat);
    final stoppingTime = boat.speed.isFinite && boat.speed > 0
        ? stoppingDistance / boat.speed
        : 0.0;
    return math.max(warning, stoppingTime);
  }

  bool _isUsableBoat(Boat boat) =>
      boat.lat.isFinite &&
      boat.lng.isFinite &&
      boat.lat.abs() <= 90 &&
      boat.lng.abs() <= 180;

  /// 地図表示用に、同じ座標近傍を東西・南北メートル平面へ移して凸包を取る。
  ///
  /// 各予測区間は「同じ凸多角形の平行移動」なので、開始・終了形状の凸包が
  /// 判定器の連続掃引と同じ外形になる。
  List<LatLng> _convexHull(List<LatLng> input) {
    if (input.length < 3) return input;
    final origin = input.first;
    final latitudeRadians = origin.latitude * math.pi / 180;
    final points = input
        .map((point) => _LocalPoint(
              (point.longitude - origin.longitude) *
                  math.pi /
                  180 *
                  6378137 *
                  math.cos(latitudeRadians),
              (point.latitude - origin.latitude) * math.pi / 180 * 6378137,
            ))
        .toList()
      ..sort((a, b) => a.x == b.x ? a.y.compareTo(b.y) : a.x.compareTo(b.x));
    final lower = <_LocalPoint>[];
    for (final point in points) {
      while (lower.length >= 2 &&
          (lower.last - lower[lower.length - 2]).cross(point - lower.last) <=
              1e-8) {
        lower.removeLast();
      }
      lower.add(point);
    }
    final upper = <_LocalPoint>[];
    for (final point in points.reversed) {
      while (upper.length >= 2 &&
          (upper.last - upper[upper.length - 2]).cross(point - upper.last) <=
              1e-8) {
        upper.removeLast();
      }
      upper.add(point);
    }
    final hull = [
      ...lower.sublist(0, lower.length - 1),
      ...upper.sublist(0, upper.length - 1),
    ];
    return hull
        .map((point) => LatLng(
              origin.latitude + point.y / 6378137 * 180 / math.pi,
              origin.longitude +
                  point.x /
                      (6378137 * math.cos(latitudeRadians)) *
                      180 /
                      math.pi,
            ))
        .toList();
  }
}

class _LocalPoint {
  final double x;
  final double y;

  const _LocalPoint(this.x, this.y);

  _LocalPoint operator -(_LocalPoint other) =>
      _LocalPoint(x - other.x, y - other.y);

  double cross(_LocalPoint other) => x * other.y - y * other.x;
}
