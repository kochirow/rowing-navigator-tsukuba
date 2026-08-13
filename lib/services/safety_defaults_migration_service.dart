import 'package:shared_preferences/shared_preferences.dart';

import '../config/risk_evaluator_config.dart';
import '../models/danger_zone_settings.dart';
import '../models/fixed_obstacle_warning_settings.dart';
import 'danger_zone_settings_service.dart';
import 'fixed_obstacle_calibration_service.dart';
import 'fixed_obstacle_warning_settings_service.dart';
import 'risk_evaluator_settings_service.dart';

/// 配布アップデート単位で、安全に関係する端末差分をコード既定値へ戻す。
///
/// 艇名・艇種・座席・チーム所属・臨時障害物は利用者データなので触らない。
/// 固定プロフィール本体はアプリassetがsource of truthで、ここではそのassetへ
/// 重ねる数値だけをリセットする。
class SafetyDefaultsMigrationService {
  static const currentGeneration = 2;
  static const _appliedGenerationKey = 'safety_defaults_generation';
  static const _sharedCachePrefix = 'shared_safety_calibration_';

  final RiskEvaluatorSettingsService _riskSettings;
  final DangerZoneSettingsService _dangerZoneSettings;
  final FixedObstacleCalibrationService _calibrations;
  final FixedObstacleWarningSettingsService _warningSettings;

  SafetyDefaultsMigrationService({
    RiskEvaluatorSettingsService? riskSettings,
    DangerZoneSettingsService? dangerZoneSettings,
    FixedObstacleCalibrationService? calibrations,
    FixedObstacleWarningSettingsService? warningSettings,
  })  : _riskSettings = riskSettings ?? RiskEvaluatorSettingsService(),
        _dangerZoneSettings = dangerZoneSettings ?? DangerZoneSettingsService(),
        _calibrations = calibrations ?? FixedObstacleCalibrationService(),
        _warningSettings =
            warningSettings ?? FixedObstacleWarningSettingsService();

  Future<bool> migrateIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    if ((prefs.getInt(_appliedGenerationKey) ?? 0) >= currentGeneration) {
      return false;
    }

    await _riskSettings.saveWarningLeadTimes(const WarningLeadTimes(
      primaryWarningLeadSeconds: primaryWarningLeadSeconds,
      advanceWarningLeadSeconds: advanceWarningLeadSeconds,
    ));
    await _dangerZoneSettings.save(DangerZoneSettings.defaults());
    await _calibrations.resetAll();
    await _warningSettings.save(FixedObstacleWarningSettings());

    // 新しい共有文書v5を読む前に、旧revisionのcacheを確実に捨てる。
    final cacheKeys =
        prefs.getKeys().where((key) => key.startsWith(_sharedCachePrefix));
    for (final key in cacheKeys.toList(growable: false)) {
      await prefs.remove(key);
    }
    // 最後に世代を書く。途中で失敗した場合は次回起動で全工程をやり直す。
    await prefs.setInt(_appliedGenerationKey, currentGeneration);
    return true;
  }
}
