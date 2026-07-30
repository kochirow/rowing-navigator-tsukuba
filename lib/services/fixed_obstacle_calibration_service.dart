import 'dart:convert';
import 'dart:math';

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/fixed_obstacle_calibration.dart';

class FixedObstacleCalibrationService {
  static const _storageKey = 'fixed_obstacle_calibrations_v1';
  static const _earthRadiusMeters = 6371000.0;

  Future<Map<String, FixedObstacleCalibration>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      final result = <String, FixedObstacleCalibration>{};
      for (final entry in decoded.entries) {
        final id = entry.key;
        final value = entry.value;
        if (id is! String || id.isEmpty || id.length > 128 || value is! Map) {
          continue;
        }
        try {
          final calibration = FixedObstacleCalibration.fromJson(
            Map<String, dynamic>.from(value),
          );
          if (!calibration.isZero) result[id] = calibration;
        } on Object {
          // 1件の壊れた値で、他の現地校正を失わない。
        }
      }
      return result;
    } on FormatException {
      return const {};
    }
  }

  Future<void> save(
    String sourceId,
    FixedObstacleCalibration calibration,
  ) async {
    _validateId(sourceId);
    _validate(calibration);
    final all = Map<String, FixedObstacleCalibration>.from(await loadAll());
    if (calibration.isZero) {
      all.remove(sourceId);
    } else {
      all[sourceId] = calibration;
    }
    await _write(all);
  }

  Future<void> reset(String sourceId) async {
    _validateId(sourceId);
    final all = Map<String, FixedObstacleCalibration>.from(await loadAll())
      ..remove(sourceId);
    await _write(all);
  }

  Future<void> resetAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
  }

  List<LatLng> translatePoints(
    List<LatLng> points,
    FixedObstacleCalibration calibration,
  ) {
    if (calibration.isZero) return List<LatLng>.unmodifiable(points);
    return points.indexed.map((entry) {
      final point = translatePoint(entry.$2, calibration);
      final vertexOffset = calibration.vertexOffsetFor(entry.$1);
      return vertexOffset.isZero
          ? point
          : translatePoint(
              point,
              FixedObstacleCalibration(
                northMeters: vertexOffset.northMeters,
                eastMeters: vertexOffset.eastMeters,
              ),
            );
    }).toList(growable: false);
  }

  LatLng translatePoint(
    LatLng point,
    FixedObstacleCalibration calibration,
  ) {
    _validate(calibration);
    final latitudeRadians = point.latitude * pi / 180;
    final latitudeDelta =
        calibration.northMeters / _earthRadiusMeters * 180 / pi;
    final longitudeScale = cos(latitudeRadians).abs();
    final longitudeDelta = longitudeScale < 1e-9
        ? 0
        : calibration.eastMeters /
            (_earthRadiusMeters * longitudeScale) *
            180 /
            pi;
    return LatLng(
      point.latitude + latitudeDelta,
      point.longitude + longitudeDelta,
    );
  }

  Future<void> _write(
    Map<String, FixedObstacleCalibration> calibrations,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    if (calibrations.isEmpty) {
      await prefs.remove(_storageKey);
      return;
    }
    final encoded = jsonEncode({
      for (final entry in calibrations.entries) entry.key: entry.value.toJson(),
    });
    await prefs.setString(_storageKey, encoded);
  }

  void _validate(FixedObstacleCalibration calibration) {
    if (!calibration.northMeters.isFinite ||
        !calibration.eastMeters.isFinite ||
        calibration.northMeters.abs() >
            FixedObstacleCalibration.maxAbsoluteOffsetMeters ||
        calibration.eastMeters.abs() >
            FixedObstacleCalibration.maxAbsoluteOffsetMeters) {
      throw const FormatException('Fixed obstacle calibration out of range');
    }
    for (final entry in calibration.vertexOffsets.entries) {
      final offset = entry.value;
      if (entry.key < 0 ||
          entry.key > FixedObstacleCalibration.maxVertexIndex ||
          !offset.northMeters.isFinite ||
          !offset.eastMeters.isFinite ||
          offset.northMeters.abs() >
              FixedObstacleCalibration.maxAbsoluteOffsetMeters ||
          offset.eastMeters.abs() >
              FixedObstacleCalibration.maxAbsoluteOffsetMeters) {
        throw const FormatException(
            'Fixed obstacle vertex offset out of range');
      }
    }
  }

  void _validateId(String sourceId) {
    if (sourceId.isEmpty || sourceId.length > 128) {
      throw const FormatException('Invalid fixed obstacle source id');
    }
  }
}
