import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/fixed_obstacle_warning_settings.dart';
import '../models/shared_safety_calibration.dart';

/// 固定対象物を警告対象にするかどうかを、端末内へ保存する。
class FixedObstacleWarningSettingsService {
  static const _storageKey = 'fixed_obstacle_warning_settings_v1';

  Future<FixedObstacleWarningSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null) return FixedObstacleWarningSettings();
    try {
      final values = jsonDecode(raw);
      if (values is! List ||
          values.any(
            (value) =>
                value is! String ||
                !SharedSafetyCalibrationState.allowedSourceIds.contains(value),
          )) {
        return FixedObstacleWarningSettings();
      }
      return FixedObstacleWarningSettings(
        disabledSourceIds: values.cast<String>().toSet(),
      );
    } catch (_) {
      return FixedObstacleWarningSettings();
    }
  }

  Future<void> save(FixedObstacleWarningSettings settings) async {
    final invalidIds = settings.disabledSourceIds.difference(
      SharedSafetyCalibrationState.allowedSourceIds,
    );
    if (invalidIds.isNotEmpty) {
      throw ArgumentError.value(invalidIds, 'disabledSourceIds');
    }
    final prefs = await SharedPreferences.getInstance();
    final ids = settings.disabledSourceIds.toList()..sort();
    await prefs.setString(_storageKey, jsonEncode(ids));
  }
}
