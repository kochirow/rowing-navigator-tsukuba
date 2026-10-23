import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/warning_audio_config.dart';
import 'package:rowing_navigator/services/warning_audio_volume_settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('normalizeWarningAudioAppVolume', () {
    test('0にはならない(警告を設定で消せない)', () {
      expect(normalizeWarningAudioAppVolume(0), warningAudioAppVolumeMin);
      expect(normalizeWarningAudioAppVolume(-1), warningAudioAppVolumeMin);
    });

    test('100%を超えない', () {
      expect(normalizeWarningAudioAppVolume(1.5), warningAudioAppVolumeMax);
    });

    test('壊れた値は小さいほうでなく既定(100%)へ戻す', () {
      expect(normalizeWarningAudioAppVolume(null), 1.0);
      expect(normalizeWarningAudioAppVolume(double.nan), 1.0);
      expect(normalizeWarningAudioAppVolume(double.infinity), 1.0);
    });

    test('10%刻みへ丸め、浮動小数の誤差を残さない', () {
      expect(normalizeWarningAudioAppVolume(0.64), 0.6);
      expect(normalizeWarningAudioAppVolume(0.66), 0.7);
      expect(normalizeWarningAudioAppVolume(0.1 * 3), 0.3);
    });

    test('既定は100%(従来どおりの音量)', () {
      expect(warningAudioAppVolumeDefault, 1.0);
    });
  });

  group('WarningAudioVolumeSettingsService', () {
    test('未保存なら100%', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await WarningAudioVolumeSettingsService().load(), 1.0);
    });

    test('保存した音量を読み戻せる', () async {
      SharedPreferences.setMockInitialValues({});
      final service = WarningAudioVolumeSettingsService();
      await service.save(0.6);
      expect(await service.load(), 0.6);
    });

    test('範囲外の保存値は範囲内へ収めて読む', () async {
      SharedPreferences.setMockInitialValues({
        'warning_audio_app_volume_v1': 0.05,
      });
      expect(await WarningAudioVolumeSettingsService().load(), 0.3);
    });
  });
}
