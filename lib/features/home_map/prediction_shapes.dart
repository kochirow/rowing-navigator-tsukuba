import 'dart:math';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/boat_model.dart';
import '../../services/collision_risk_evaluator_service.dart';
import '../../services/map_render_update_policy.dart';
import '../../services/ship_domain_service.dart';
import '../../services/swept_outline_service.dart';
import '../../theme/boat_palette.dart';
import '../../theme/map_layer_spec.dart';
import '../../theme/nav_palette.dart';

/// 地図に描く、艇ごとの予測の図形(**表示専用**)。
///
/// 安全判定には使わない。形は `getShipDomains(headingReliable: true)` で作り、
/// 判定用の拡張(GPS帯・低速時の横拡張)を混ぜない(不変条件6)。
///
/// [night] は航行中の「夜の配色」(暗い地図)。自艇の予測を白、他艇を赤系の
/// 細線にし、停止距離=実線・届く範囲=破線で区別する。明るい地図では
/// 従来どおり(黒・橙・赤)。
({Set<Polygon> polygons, Set<Polyline> polylines}) buildPredictionShapes({
  required List<Boat> boats,
  required String? myBoatId,
  required CollisionRiskEvaluatorService evalService,
  required double warningTimeSeconds,
  required bool night,
}) {
  // 1艇につき3つの図形だけを描く。
  //   ① 船体領域(t=0)     … いま艇がある場所
  //   ② 掃引外形(凸包)     … どこまで届くか
  //   ③ 停止距離ライン     … どこまでなら止まれるか
  // 以前はサンプルごとに2枚(最大48枚)を重ねていたが、中身は同じ
  // 六角形の平行移動の繰り返しで、情報は増えないまま画面が埋まる。
  final shipDomainService = ShipDomainService();
  final newShipDomains = <Polygon>{};
  final newStoppingDistanceLines = <Polyline>{};
  for (final boat in boats) {
    final speed = boat.speed;
    final stoppingDistance = evalService.getStoppingDistance(boat);
    final warningDistance = max(
      stoppingDistance,
      warningTimeSeconds * speed,
    );
    final sampleDistances = shipDomainDisplaySampleDistances(warningDistance);

    // 地図の表示形状は従来どおり。低速時の横拡張は安全判定専用で、
    // 描画すると停止のたびに領域が太って見え、意味を誤解させる(不変条件6)。
    ShipDomains domainsAt(double distance) {
      final t = speed > 0 ? distance / speed : 0.0;
      return shipDomainService.getShipDomains(
        evalService.predictPosition(boat, t),
        headingReliable: true,
      );
    }

    // 夜の配色では、自艇の予測を白、他艇の予測を他艇の色(赤系)の
    // 細線にする。停止距離=実線・届く範囲=破線で区別する(色では分けない)。
    // 明るい地図では従来どおり(黒・橙・赤)。
    final isMine = boat.boatId == myBoatId;
    final nightLine = isMine
        ? NavPalette.selfPrediction
        : BoatPalette.otherBoat.withValues(alpha: 0.6);

    // ① 船体領域。塗るのはここだけで、いま艇が在る場所を示す。
    newShipDomains.add(Polygon(
      polygonId: PolygonId('ship_body_${boat.boatId}'),
      points: domainsAt(0).shipBodyDomain.points,
      strokeWidth: 2,
      strokeColor: night
          ? nightLine.withValues(alpha: 0.5)
          : Colors.black.withValues(alpha: 0.45),
      fillColor:
          night ? Colors.transparent : Colors.black.withValues(alpha: 0.08),
      zIndex: predictionShapeZIndex,
    ));

    // ② 掃引外形。「塗り = 実在する危険」「線 = 予測」の規則を守り、
    // 塗りはほぼ透明にして輪郭で伝える。
    final sweptPoints = sweptOutline([
      for (final distance in sampleDistances)
        domainsAt(distance).exclusiveDomain.points,
    ]);
    if (sweptPoints.length >= 3 && night) {
      // 夜の配色: 破線にするためポリラインの閉じた輪で描く
      // (ポリゴンの輪郭は破線にできない)。
      newStoppingDistanceLines.add(Polyline(
        polylineId: PolylineId('sweep_outline_${boat.boatId}'),
        points: [...sweptPoints, sweptPoints.first],
        width: 2,
        color: nightLine.withValues(alpha: isMine ? 0.55 : 0.45),
        patterns: [PatternItem.dash(12), PatternItem.gap(10)],
        zIndex: predictionShapeZIndex,
      ));
    } else if (sweptPoints.length >= 3) {
      newShipDomains.add(Polygon(
        polygonId: PolygonId('sweep_outline_${boat.boatId}'),
        points: sweptPoints,
        strokeWidth: 3,
        strokeColor: const Color(0xFFF9A825).withValues(alpha: 0.9),
        fillColor: const Color(0xFFF9A825).withValues(alpha: 0.06),
        zIndex: predictionShapeZIndex,
      ));
    }

    // ③ 停止距離の位置での排他領域を、閉じた輪のポリラインで描く。
    // 速度0のときは掃引そのものが無いので出さない。
    if (speed > 0) {
      final stopPoints = domainsAt(stoppingDistance).exclusiveDomain.points;
      if (stopPoints.length >= 3) {
        newStoppingDistanceLines.add(Polyline(
          polylineId: PolylineId('stop_line_${boat.boatId}'),
          points: [...stopPoints, stopPoints.first],
          width: 2,
          color: night
              ? nightLine.withValues(alpha: isMine ? 0.85 : 0.6)
              : const Color(0xFFD32F2F),
          zIndex: predictionShapeZIndex,
        ));
      }
    }
  }
  return (polygons: newShipDomains, polylines: newStoppingDistanceLines);
}
