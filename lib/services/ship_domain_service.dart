import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/types/ship_domain_type.dart';
import 'dart:math';

import '../config/boat_config.dart';
import '../models/boat_model.dart';
import '../types/boat_type.dart';
import '../utils/geo_math.dart';

class ShipDomainParam {
  final double h;
  final double w;
  final double s;

  ShipDomainParam({
    required this.h,
    required this.w,
    required this.s,
  });
}

class ShipDomains {
  final Polygon shipBodyDomain;
  final Polygon exclusiveDomain;
  final Polygon cautionDomain;

  List<Polygon> get allDomains =>
      [shipBodyDomain, exclusiveDomain, cautionDomain];

  ShipDomains({
    required this.shipBodyDomain,
    required this.exclusiveDomain,
    required this.cautionDomain,
  });
}

class ShipDomainService {
// 一つの船舶領域の全頂点の地理座標を求める関数
  List<LatLng> getShipDomainPoints(LatLng center, double heading, double height,
      double width, double sideHeight) {
    double halfHeight = height / 2;
    double halfWidth = width / 2;
    double halfSideHeight = sideHeight / 2;

    // 船舶領域の頂点のオフセット（距離と方位角）を定義
    List<Map<String, double>> offsets = [
      {"distance": halfHeight, "angle": heading}, // 1
      {
        "distance": sqrt(pow(halfSideHeight, 2) + pow(halfWidth, 2)),
        "angle": heading + 90 - atan2(halfSideHeight, halfWidth) * 180 / pi
      }, // 2
      {
        "distance": sqrt(pow(halfSideHeight, 2) + pow(halfWidth, 2)),
        "angle": heading + 90 + atan2(halfSideHeight, halfWidth) * 180 / pi
      }, // 3
      {"distance": halfHeight, "angle": heading + 180}, // 4
      {
        "distance": sqrt(pow(halfSideHeight, 2) + pow(halfWidth, 2)),
        "angle": heading - 90 - atan2(halfSideHeight, halfWidth) * 180 / pi
      }, // 5
      {
        "distance": sqrt(pow(halfSideHeight, 2) + pow(halfWidth, 2)),
        "angle": heading - 90 + atan2(halfSideHeight, halfWidth) * 180 / pi
      }, // 6
    ];

    List<LatLng> vertices = [];
    for (var offset in offsets) {
      LatLng vertex =
          computeOffset(center, offset["distance"]!, offset["angle"]!);
      vertices.add(vertex);
    }

    return vertices;
  }

  ShipDomains getShipDomains(Boat boat) {
    BoatType boatType = BoatType.values.byName("single");
    ShipDomainParam shipBodyParam; // 船体領域
    ShipDomainParam exclusiveParam; // 排他領域
    ShipDomainParam attentionParam; // 注意領域

    switch (boatType) {
      case BoatType.single:
        shipBodyParam = boatConfigs.single.shipDomainParams.shipBodyParam;
        exclusiveParam = boatConfigs.single.shipDomainParams.exclusiveParam;
        attentionParam = boatConfigs.single.shipDomainParams.attentionParam;
        break;
      case BoatType.double:
        shipBodyParam = boatConfigs.single.shipDomainParams.shipBodyParam;
        exclusiveParam = boatConfigs.single.shipDomainParams.exclusiveParam;
        attentionParam = boatConfigs.single.shipDomainParams.attentionParam;
        break;
      default:
        shipBodyParam = boatConfigs.double.shipDomainParams.shipBodyParam;
        exclusiveParam = boatConfigs.double.shipDomainParams.exclusiveParam;
        attentionParam = boatConfigs.double.shipDomainParams.attentionParam;
        break;
    }
    final shipDomains = ShipDomains(
      shipBodyDomain: Polygon(
        polygonId: PolygonId(ShipDomainType.shipBodyDomain.value),
        points: getShipDomainPoints(LatLng(boat.lat, boat.lng), boat.heading,
            shipBodyParam.h, shipBodyParam.w, shipBodyParam.s),
        strokeWidth: 0,
        fillColor: Colors.red.withOpacity(0.9),
      ),
      exclusiveDomain: Polygon(
        polygonId: PolygonId(ShipDomainType.exclusiveDomain.value),
        points: getShipDomainPoints(LatLng(boat.lat, boat.lng), boat.heading,
            exclusiveParam.h, exclusiveParam.w, exclusiveParam.s),
        strokeWidth: 0,
        fillColor: Colors.yellow.withOpacity(0.6),
      ),
      cautionDomain: Polygon(
        polygonId: PolygonId(ShipDomainType.cautionDomain.value),
        points: getShipDomainPoints(LatLng(boat.lat, boat.lng), boat.heading,
            attentionParam.h, attentionParam.w, attentionParam.s),
        strokeWidth: 0,
        fillColor: Colors.green.withOpacity(0.3),
      ),
    );
    return shipDomains;
  }
}
