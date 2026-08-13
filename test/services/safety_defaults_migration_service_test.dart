import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/risk_evaluator_config.dart';
import 'package:rowing_navigator/models/danger_zone_settings.dart';
import 'package:rowing_navigator/models/fixed_obstacle_warning_settings.dart';
import 'package:rowing_navigator/services/danger_zone_settings_service.dart';
import 'package:rowing_navigator/services/fixed_obstacle_calibration_service.dart';
import 'package:rowing_navigator/services/fixed_obstacle_warning_settings_service.dart';
import 'package:rowing_navigator/services/risk_evaluator_settings_service.dart';
import 'package:rowing_navigator/services/safety_defaults_migration_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('アップデート時に安全数値と共有cacheを一度だけ既定値へ戻す', () async {
    SharedPreferences.setMockInitialValues({
      'safety_defaults_generation': 1,
      'risk_primary_warning_lead_seconds_v2': 11.0,
      'risk_advance_warning_lead_seconds_v2': 15.0,
      'danger_zone_offset_v1_shore_water': 9.0,
      'fixed_obstacle_calibrations_v1':
          '{"bridge_suigo":{"northMeters":2,"eastMeters":0}}',
      'fixed_obstacle_warning_settings_v1': '["bridge_suigo"]',
      'shared_safety_calibration_v1_team-a': '{"revision":9}',
    });
    final service = SafetyDefaultsMigrationService();

    expect(await service.migrateIfNeeded(), isTrue);
    final leadTimes =
        await RiskEvaluatorSettingsService().loadWarningLeadTimes();
    expect(leadTimes.primaryWarningLeadSeconds, primaryWarningLeadSeconds);
    expect(leadTimes.advanceWarningLeadSeconds, advanceWarningLeadSeconds);
    final zones = await DangerZoneSettingsService().load();
    expect(
      zones[DangerZoneKind.shore].waterSideMeters,
      DangerZoneSettings.defaults()[DangerZoneKind.shore].waterSideMeters,
    );
    expect(await FixedObstacleCalibrationService().loadAll(), isEmpty);
    expect(
      (await FixedObstacleWarningSettingsService().load()).disabledSourceIds,
      FixedObstacleWarningSettings.defaultDisabledSourceIds,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('shared_safety_calibration_v1_team-a'), isFalse);

    await RiskEvaluatorSettingsService().saveWarningLeadTimes(
      const WarningLeadTimes(
        primaryWarningLeadSeconds: 11,
        advanceWarningLeadSeconds: 15,
      ),
    );
    expect(await service.migrateIfNeeded(), isFalse);
    expect(
      (await RiskEvaluatorSettingsService().loadWarningLeadTimes())
          .advanceWarningLeadSeconds,
      15,
    );
  });
}
