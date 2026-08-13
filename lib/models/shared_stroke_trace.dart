import 'dart:convert';
import 'dart:typed_data';

import '../config/stroke_trace_config.dart';

/// 1ストロークぶんの艇速波形を、監視端末へ渡すための最小表現。
///
/// **監視のための表示専用データである。** 受け取った側は地図描画にも
/// 衝突評価にも使わない(他艇の警告状態と同じ扱い: 不変条件12)。
/// 位置共有の `live_positions` とは別ノードへ置き、監視端末が選んだ1艇だけを
/// 購読する。全艇が全艇ぶんを受け取る位置共有の経路へ混ぜると、
/// 12×12のfan-outで転送量が跳ね上がる。
///
/// 波形は「そのストロークの平均艇速からの差」[m/s] の配列で、平均は0。
/// 絶対艇速は `baseSpeedMetersPerSecond + relativeSpeeds[i]` で復元する。
class SharedStrokeTrace {
  /// このストロークのキャッチ時刻(送信端末のGNSS/センサ時刻基準)。
  final DateTime strokeStartedAt;
  final Duration strokeDuration;

  /// このストロークの平均艇速 [m/s]。
  final double baseSpeedMetersPerSecond;

  /// 平均からの差 [m/s]。長さは [sharedStrokeWaveformSamples] 前後。
  final List<double> relativeSpeeds;

  final double spm;
  final double confidence;
  final double distancePerStrokeMeters;
  final double catchSpeedLossMetersPerSecond;
  final double lateDriveSpeedGainMetersPerSecond;
  final double recoverySpeedRetention;
  final double finishPhaseFraction;

  /// サーバー到着時刻。端末時計のずれに依存せず鮮度を測るために使う。
  final DateTime? serverUpdatedAt;

  const SharedStrokeTrace({
    required this.strokeStartedAt,
    required this.strokeDuration,
    required this.baseSpeedMetersPerSecond,
    required this.relativeSpeeds,
    required this.spm,
    required this.confidence,
    required this.distancePerStrokeMeters,
    required this.catchSpeedLossMetersPerSecond,
    required this.lateDriveSpeedGainMetersPerSecond,
    required this.recoverySpeedRetention,
    required this.finishPhaseFraction,
    this.serverUpdatedAt,
  });

  DateTime get strokeEndedAt => strokeStartedAt.add(strokeDuration);

  /// 推定フィニッシュの時刻。ドライブ区間の背景を描くために使う。
  DateTime get finishAt => strokeStartedAt.add(Duration(
        microseconds: (strokeDuration.inMicroseconds *
                finishPhaseFraction.clamp(0.0, 1.0))
            .round(),
      ));

  /// 絶対艇速 [m/s] の列。
  List<double> get absoluteSpeeds => relativeSpeeds
      .map((value) =>
          (baseSpeedMetersPerSecond + value).clamp(0.0, double.infinity))
      .toList(growable: false);

  Map<String, Object?> toRtdbJson({Object? serverUpdatedAt}) => {
        'o': strokeStartedAt.toUtc().millisecondsSinceEpoch,
        'd': strokeDuration.inMilliseconds,
        'b': (baseSpeedMetersPerSecond * 100).round(),
        'w': StrokeWaveformCodec.encode(relativeSpeeds),
        'r': (spm * 10).round(),
        'c': (confidence * 100).round(),
        'l': (distancePerStrokeMeters * 100).round(),
        'k': (catchSpeedLossMetersPerSecond * 100).round(),
        'g': (lateDriveSpeedGainMetersPerSecond * 100).round(),
        'h': (recoverySpeedRetention * 100).round(),
        'p': (finishPhaseFraction * 1000).round(),
        'u': serverUpdatedAt ??
            this.serverUpdatedAt?.toUtc().millisecondsSinceEpoch,
      }..removeWhere((_, value) => value == null);

  /// 受信データの検証込み復元。**壊れた1件で監視表示を止めない**ため、
  /// 判定できない値は例外ではなく null で返す。
  static SharedStrokeTrace? fromRtdbJson(Map<Object?, Object?> json) {
    final startMs = _intOf(json['o']);
    final durationMs = _intOf(json['d']);
    final baseCm = _intOf(json['b']);
    final waveform = json['w'];
    if (startMs == null || durationMs == null || baseCm == null) return null;
    if (waveform is! String) return null;
    // 現実のストロークは12〜65spm = 0.92〜5.0秒。範囲外は表示しない。
    if (durationMs < 800 || durationMs > 5200) return null;
    if (baseCm < 0 || baseCm > 3000) return null;
    final relativeSpeeds = StrokeWaveformCodec.decode(waveform);
    if (relativeSpeeds == null) return null;

    final serverMs = _intOf(json['u']);
    return SharedStrokeTrace(
      strokeStartedAt:
          DateTime.fromMillisecondsSinceEpoch(startMs, isUtc: true).toLocal(),
      strokeDuration: Duration(milliseconds: durationMs),
      baseSpeedMetersPerSecond: baseCm / 100,
      relativeSpeeds: relativeSpeeds,
      spm: (_intOf(json['r']) ?? 0) / 10,
      confidence: ((_intOf(json['c']) ?? 0) / 100).clamp(0.0, 1.0),
      distancePerStrokeMeters: (_intOf(json['l']) ?? 0) / 100,
      catchSpeedLossMetersPerSecond: (_intOf(json['k']) ?? 0) / 100,
      lateDriveSpeedGainMetersPerSecond: (_intOf(json['g']) ?? 0) / 100,
      recoverySpeedRetention: ((_intOf(json['h']) ?? 0) / 100).clamp(0.0, 1.0),
      finishPhaseFraction: ((_intOf(json['p']) ?? 500) / 1000).clamp(0.0, 1.0),
      serverUpdatedAt: serverMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(serverMs, isUtc: true)
              .toLocal(),
    );
  }

  static int? _intOf(Object? value) =>
      value is num && value.isFinite ? value.toInt() : null;
}

/// 波形を1点1バイト(符号付き cm/s)へ量子化し、base64で運ぶ。
///
/// 48点で64文字。JSONの数値配列(1点あたり最低3文字 + 区切り)より
/// 半分以下になり、RTDBの1書込を250バイト前後に収められる。
class StrokeWaveformCodec {
  static String encode(List<double> relativeSpeeds) {
    final bytes = Int8List(relativeSpeeds.length);
    for (var index = 0; index < relativeSpeeds.length; index++) {
      final value = relativeSpeeds[index];
      if (!value.isFinite) {
        bytes[index] = 0;
        continue;
      }
      bytes[index] = (value / strokeWaveformQuantumMetersPerSecond)
          .round()
          .clamp(-strokeWaveformMaximumQuantum, strokeWaveformMaximumQuantum);
    }
    return base64Encode(bytes.buffer.asUint8List());
  }

  static List<double>? decode(String encoded) {
    if (encoded.isEmpty || encoded.length > 512) return null;
    Uint8List raw;
    try {
      raw = base64Decode(encoded);
    } catch (_) {
      return null;
    }
    // 8点未満は形として読めず、128点超は想定外の巨大payload。
    if (raw.length < 8 || raw.length > 128) return null;
    final signed = raw.buffer.asInt8List(raw.offsetInBytes, raw.length);
    return List<double>.generate(
      signed.length,
      (index) => signed[index] * strokeWaveformQuantumMetersPerSecond,
      growable: false,
    );
  }
}
