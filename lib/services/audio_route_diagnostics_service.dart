import 'package:flutter/services.dart';

/// OSが認識している音声セッション・出力経路を、個人を識別しない形で読む。
///
/// デバイス名やBluetooth名は保存せず、アプリ同士の音声セッション競合を
/// 推定するために必要な状態だけをスナップショットへ含める。
class AudioRouteDiagnosticsService {
  static const _channel = MethodChannel(
    'jp.kosei.rowingnavigator.tsukuba/audio_diagnostics',
  );

  Future<Map<String, dynamic>> snapshot() async {
    try {
      final value = await _channel.invokeMethod<Object?>('snapshot');
      if (value is Map) {
        return {
          'available': true,
          ...Map<String, dynamic>.from(value),
        };
      }
      return const {
        'available': false,
        'errorType': 'invalid_platform_response',
      };
    } on MissingPluginException {
      return const {
        'available': false,
        'errorType': 'missing_plugin',
      };
    } catch (error) {
      return {
        'available': false,
        'errorType': error.runtimeType.toString(),
      };
    }
  }
}
