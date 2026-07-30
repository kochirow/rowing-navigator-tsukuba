import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/risk_evaluator_config.dart';
import 'package:rowing_navigator/services/risk_evaluator_settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = RiskEvaluatorSettingsService();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('未保存時は本警告10秒・予告13秒', () async {
    final values = await service.loadWarningLeadTimes();
    expect(values.primaryWarningLeadSeconds, primaryWarningLeadSeconds);
    expect(values.advanceWarningLeadSeconds, advanceWarningLeadSeconds);
  });

  test('本警告と予告を保存して再読込できる', () async {
    await service.saveWarningLeadTimes(const WarningLeadTimes(
      primaryWarningLeadSeconds: 11.0,
      advanceWarningLeadSeconds: 15.0,
    ));
    final values = await service.loadWarningLeadTimes();
    expect(values.primaryWarningLeadSeconds, 11.0);
    expect(values.advanceWarningLeadSeconds, 15.0);
  });

  test('保存済みv1の単一値は予告時間へ移行する', () async {
    SharedPreferences.setMockInitialValues({
      'risk_warning_time_seconds_v1': 15.0,
    });
    final values = await service.loadWarningLeadTimes();
    expect(values.primaryWarningLeadSeconds, primaryWarningLeadSeconds);
    expect(values.advanceWarningLeadSeconds, 15.0);
  });

  test('範囲外または順序違反は安全な2値へ補正する', () async {
    await service.saveWarningLeadTimes(const WarningLeadTimes(
      primaryWarningLeadSeconds: 30.0,
      advanceWarningLeadSeconds: 1.0,
    ));
    final values = await service.loadWarningLeadTimes();
    expect(
      values.primaryWarningLeadSeconds,
      greaterThanOrEqualTo(minPrimaryWarningLeadSeconds),
    );
    expect(
      values.advanceWarningLeadSeconds,
      greaterThan(values.primaryWarningLeadSeconds),
    );

    await service.saveWarningLeadTimes(const WarningLeadTimes(
      primaryWarningLeadSeconds: 12.0,
      advanceWarningLeadSeconds: 12.0,
    ));
    final ordered = await service.loadWarningLeadTimes();
    expect(
      ordered.advanceWarningLeadSeconds,
      greaterThan(ordered.primaryWarningLeadSeconds),
    );
  });
}
