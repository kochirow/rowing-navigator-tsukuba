import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../utils/geo_math.dart';
import '../utils/metric_polygon_buffer.dart';

/// 固定流木の同梱形状に適用する、小さな永続更新値。
class ManagedHazardState {
  static const documentId = 'fixed_driftwood_01';

  /// 共有校正を持つ、従来からの固定流木のプロフィールID。
  /// 追加の流木は通常の基準線として扱い、この1件の校正を誤適用しない。
  static const sourceId = 'driftwood_estuary';
  static const kind = 'fixed_driftwood';
  static const baseShapeVersion = 1;
  static const minScale = 0.5;
  static const maxScale = 3.0;
  static const maxOutwardMarginMeters = 30.0;
  // 固定流木を誤操作で別地域へ飛ばさないための運用ガード。
  // 現在の桜川・河口周辺と同梱データの範囲を含む。
  static const minAllowedLatitude = 36.060;
  static const maxAllowedLatitude = 36.100;
  static const minAllowedLongitude = 140.195;
  static const maxAllowedLongitude = 140.230;

  final LatLng center;
  final double lengthScale;
  final double widthScale;
  final double rotationDegrees;
  final double outwardMarginMeters;
  final int revision;

  const ManagedHazardState({
    required this.center,
    this.lengthScale = 1,
    this.widthScale = 1,
    this.rotationDegrees = 0,
    this.outwardMarginMeters = 0,
    this.revision = 0,
  });

  factory ManagedHazardState.forBaseShape(List<LatLng> points) {
    if (points.length < 3) {
      throw ArgumentError.value(points.length, 'points', 'must have 3+ points');
    }
    return ManagedHazardState(center: _meanCenter(points));
  }

  factory ManagedHazardState.fromMap(Map<String, dynamic> map) {
    final center = map['center'];
    final version = map['baseShapeVersion'];
    final revision = map['revision'];
    if (map['kind'] != kind ||
        version != baseShapeVersion ||
        center is! GeoPoint ||
        revision is! int) {
      throw const FormatException('Invalid managed hazard header');
    }
    final state = ManagedHazardState(
      center: LatLng(center.latitude, center.longitude),
      lengthScale: _finiteDouble(map['lengthScale'], 'lengthScale'),
      widthScale: _finiteDouble(map['widthScale'], 'widthScale'),
      rotationDegrees: _finiteDouble(map['rotationDegrees'], 'rotationDegrees'),
      outwardMarginMeters:
          _finiteDouble(map['outwardMarginMeters'], 'outwardMarginMeters'),
      revision: revision,
    );
    state.validate();
    return state;
  }

  factory ManagedHazardState.fromCacheMap(Map<String, dynamic> map) {
    final state = ManagedHazardState(
      center: LatLng(
        _finiteDouble(map['centerLat'], 'centerLat'),
        _finiteDouble(map['centerLng'], 'centerLng'),
      ),
      lengthScale: _finiteDouble(map['lengthScale'], 'lengthScale'),
      widthScale: _finiteDouble(map['widthScale'], 'widthScale'),
      rotationDegrees: _finiteDouble(map['rotationDegrees'], 'rotationDegrees'),
      outwardMarginMeters:
          _finiteDouble(map['outwardMarginMeters'], 'outwardMarginMeters'),
      revision: map['revision'] as int,
    );
    state.validate();
    return state;
  }

  static double _finiteDouble(Object? value, String name) {
    if (value is! num || !value.isFinite) {
      throw FormatException('$name must be finite');
    }
    return value.toDouble();
  }

  void validate() {
    if (center.latitude < minAllowedLatitude ||
        center.latitude > maxAllowedLatitude ||
        center.longitude < minAllowedLongitude ||
        center.longitude > maxAllowedLongitude ||
        lengthScale < minScale ||
        lengthScale > maxScale ||
        widthScale < minScale ||
        widthScale > maxScale ||
        rotationDegrees < -180 ||
        rotationDegrees > 180 ||
        outwardMarginMeters < 0 ||
        outwardMarginMeters > maxOutwardMarginMeters ||
        revision < 0) {
      throw const FormatException('Managed hazard value is out of range');
    }
  }

  ManagedHazardState copyWith({
    LatLng? center,
    double? lengthScale,
    double? widthScale,
    double? rotationDegrees,
    double? outwardMarginMeters,
    int? revision,
  }) {
    return ManagedHazardState(
      center: center ?? this.center,
      lengthScale: lengthScale ?? this.lengthScale,
      widthScale: widthScale ?? this.widthScale,
      rotationDegrees: rotationDegrees ?? this.rotationDegrees,
      outwardMarginMeters: outwardMarginMeters ?? this.outwardMarginMeters,
      revision: revision ?? this.revision,
    );
  }

  Map<String, dynamic> toFirestoreMap({
    required String updatedBy,
    required Object updatedAt,
    Map<String, dynamic>? previousState,
  }) {
    validate();
    return {
      'kind': kind,
      'baseShapeVersion': baseShapeVersion,
      'center': GeoPoint(center.latitude, center.longitude),
      'lengthScale': lengthScale,
      'widthScale': widthScale,
      'rotationDegrees': rotationDegrees,
      'outwardMarginMeters': outwardMarginMeters,
      'revision': revision,
      'updatedAt': updatedAt,
      'updatedBy': updatedBy,
      if (previousState != null) 'previousState': previousState,
    };
  }

  Map<String, dynamic> toPreviousStateMap() => {
        'center': GeoPoint(center.latitude, center.longitude),
        'lengthScale': lengthScale,
        'widthScale': widthScale,
        'rotationDegrees': rotationDegrees,
        'outwardMarginMeters': outwardMarginMeters,
        'revision': revision,
      };

  Map<String, dynamic> toCacheMap() => {
        'centerLat': center.latitude,
        'centerLng': center.longitude,
        'lengthScale': lengthScale,
        'widthScale': widthScale,
        'rotationDegrees': rotationDegrees,
        'outwardMarginMeters': outwardMarginMeters,
        'revision': revision,
      };
}

/// 基準外周を1枚の塗りつぶしポリゴンに変換する。
class ManagedHazardTransformer {
  final MetricPolygonBuffer _polygonBuffer;

  const ManagedHazardTransformer({
    MetricPolygonBuffer polygonBuffer = const MetricPolygonBuffer(),
  }) : _polygonBuffer = polygonBuffer;

  List<LatLng> transform(
    List<LatLng> rawBasePoints,
    ManagedHazardState state,
  ) {
    state.validate();
    final basePoints = _withoutDuplicateClosingPoint(rawBasePoints);
    if (basePoints.length < 3) return const [];
    final baseCenter = _meanCenter(basePoints);
    final local = basePoints
        .map((point) => _toLocalMeters(baseCenter, point))
        .toList(growable: false);
    final longAxis = _principalAxisRadians(local);
    final rotation = longAxis + degreesToRadians(state.rotationDegrees);

    final transformed = local.map((point) {
      final alignedX = point.x * cos(longAxis) + point.y * sin(longAxis);
      final alignedY = -point.x * sin(longAxis) + point.y * cos(longAxis);
      final x = alignedX * state.lengthScale;
      final y = alignedY * state.widthScale;
      final east = x * cos(rotation) - y * sin(rotation);
      final north = x * sin(rotation) + y * cos(rotation);
      return _fromLocalMeters(state.center, east, north);
    }).toList(growable: false);
    // 外側余裕は重心から各頂点を放射状に動かすのではなく、
    // 共有形状の各辺から指定した実距離だけ外へ広げる。
    return _polygonBuffer.expand(
      transformed,
      state.outwardMarginMeters,
    );
  }

  static List<LatLng> _withoutDuplicateClosingPoint(List<LatLng> points) {
    if (points.length > 3 && distanceMeters(points.first, points.last) < 0.05) {
      return points.sublist(0, points.length - 1);
    }
    return List<LatLng>.from(points);
  }

  static double _principalAxisRadians(List<_LocalPoint> points) {
    var xx = 0.0;
    var yy = 0.0;
    var xy = 0.0;
    for (final point in points) {
      xx += point.x * point.x;
      yy += point.y * point.y;
      xy += point.x * point.y;
    }
    return 0.5 * atan2(2 * xy, xx - yy);
  }
}

class _LocalPoint {
  final double x;
  final double y;
  const _LocalPoint(this.x, this.y);
}

LatLng _meanCenter(List<LatLng> points) {
  final usable =
      points.length > 3 && distanceMeters(points.first, points.last) < 0.05
          ? points.sublist(0, points.length - 1)
          : points;
  return LatLng(
    usable.map((p) => p.latitude).reduce((a, b) => a + b) / usable.length,
    usable.map((p) => p.longitude).reduce((a, b) => a + b) / usable.length,
  );
}

_LocalPoint _toLocalMeters(LatLng origin, LatLng point) {
  const earthRadius = 6378137.0;
  final meanLat = degreesToRadians((origin.latitude + point.latitude) / 2);
  final east = degreesToRadians(point.longitude - origin.longitude) *
      cos(meanLat) *
      earthRadius;
  final north =
      degreesToRadians(point.latitude - origin.latitude) * earthRadius;
  return _LocalPoint(east, north);
}

LatLng _fromLocalMeters(LatLng origin, double east, double north) {
  const earthRadius = 6378137.0;
  final lat = origin.latitude + radiansToDegrees(north / earthRadius);
  final lng = origin.longitude +
      radiansToDegrees(
          east / (earthRadius * cos(degreesToRadians(origin.latitude))));
  return LatLng(lat, lng);
}
