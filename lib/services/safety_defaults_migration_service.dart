import 'package:flutter/foundation.dart';
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

  /// 起動時に移行を待つ上限。端末の保存領域は通常数ミリ秒で応答する。
  /// これを超えて止まるなら、移行を諦めてアプリを開く方を選ぶ(原則1)。
  static const startupTimeout = Duration(seconds: 3);

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

  /// 起動時の移行。**失敗しても応答が止まっても、例外を出さずに終わる。**
  ///
  /// 移行が終わらないとアプリが開かず、航行も監視も記録も使えなくなる。
  /// それよりは、端末に残っている値のまま開く方がよい(原則1)。
  /// 世代番号は最後に書くので、失敗した移行は次の起動で最初からやり直す。
  /// 上限を超えた移行は裏で続くことがあるが、書く値はコード既定値だけである。
  Future<void> migrateOnStartup({Duration timeout = startupTimeout}) async {
    try {
      await migrateIfNeeded().timeout(timeout);
    } catch (error) {
      debugPrint('安全設定の既定値への移行を完了できませんでした(起動は続けます): $error');
    }
  }

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
