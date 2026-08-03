import 'dart:math' as math;
import 'dart:typed_data';

import '../config/stroke_trace_config.dart';
import '../models/shared_stroke_trace.dart';
import 'stroke_speed_trace.dart';

/// 監視端末が受け取った1ストロークずつの波形を連結し、
/// 漕手側と同じ「流れるグラフ」へ組み立てる(純Dart)。
///
/// 受信は1ストローク(約2〜3秒)ごとなので、そのまま描くと2〜3秒に一度
/// 画面が跳ねる。到着からの経過を右端へ足して時間軸を進めることで、
/// 受信間隔よりも滑らかに流せる。**データが来なくなれば線は右端から
/// 途切れる。** 空白を埋めて「変動がなかった」と読ませない(原則6)。
class StrokeTraceHistory {
  final List<SharedStrokeTrace> _traces = <SharedStrokeTrace>[];
  DateTime? _lastReceivedAt;
  DateTime? _lastSampleAt;

  SharedStrokeTrace? get latest => _traces.isEmpty ? null : _traces.last;

  bool get isEmpty => _traces.isEmpty;

  void clear() {
    _traces.clear();
    _lastReceivedAt = null;
    _lastSampleAt = null;
  }

  /// 同じストロークの再送は捨て、古い順に保つ。
  void add(SharedStrokeTrace trace, {required DateTime receivedAt}) {
    if (trace.relativeSpeeds.length < 2) return;
    final existing = _traces.indexWhere(
      (value) => value.strokeStartedAt == trace.strokeStartedAt,
    );
    if (existing >= 0) {
      _traces[existing] = trace;
    } else {
      _traces.add(trace);
      _traces.sort((a, b) => a.strokeStartedAt.compareTo(b.strokeStartedAt));
    }
    while (_traces.length > sharedStrokeTraceHistoryStrokes) {
      _traces.removeAt(0);
    }
    _lastReceivedAt = receivedAt;
    _lastSampleAt = _traces.last.strokeEndedAt;
  }

  /// 最後に受け取った波形の末尾が、いま何秒前のものか。
  ///
  /// 送信端末とこの端末の時計ずれを含まないよう、受信時刻からの経過だけで
  /// 測る。監視画面には「◯秒前のストローク」としてそのまま出す。
  Duration? ageSince(DateTime now) {
    final receivedAt = _lastReceivedAt;
    if (receivedAt == null) return null;
    final age = now.difference(receivedAt);
    return age.isNegative ? Duration.zero : age;
  }

  bool isStale(DateTime now) {
    final age = ageSince(now);
    return age == null ||
        age > const Duration(seconds: sharedStrokeTraceFreshnessSeconds);
  }

  /// 表示する時間窓 [秒]。最新ストロークの周期から2ストロークぶんを取る。
  double windowSeconds() {
    final latest = this.latest;
    if (latest == null) return strokeTraceFallbackWindowSeconds;
    final seconds = latest.strokeDuration.inMilliseconds /
        1000 *
        strokeTraceStrokesOnScreen;
    if (!seconds.isFinite || seconds <= 0) {
      return strokeTraceFallbackWindowSeconds;
    }
    return seconds.clamp(
      strokeTraceMinimumWindowSeconds,
      strokeTraceMaximumWindowSeconds,
    );
  }

  /// 連結した窓を切り出す。受信が無ければ null。
  ///
  /// 時間軸は「最後のサンプル時刻 + 受信からの経過」で進める。送信端末の
  /// 時計をこの端末の時計と直接比べないため、時計ずれで未来や過去へ
  /// 飛ばない。
  StrokeSpeedTraceWindow? window({required DateTime now}) {
    final lastSampleAt = _lastSampleAt;
    final receivedAt = _lastReceivedAt;
    if (_traces.isEmpty || lastSampleAt == null || receivedAt == null) {
      return null;
    }
    final elapsed = now.difference(receivedAt);
    final endMs = lastSampleAt.millisecondsSinceEpoch +
        (elapsed.isNegative ? 0 : elapsed.inMilliseconds);
    final span = windowSeconds();
    final startMs = endMs - span * 1000;

    final times = <double>[];
    final speeds = <double>[];
    final catchTimesMs = <double>[];
    for (final trace in _traces) {
      final startedMs = trace.strokeStartedAt.millisecondsSinceEpoch.toDouble();
      final durationMs = trace.strokeDuration.inMilliseconds.toDouble();
      final samples = trace.relativeSpeeds.length;
      if (startedMs + durationMs < startMs) continue;
      if (startedMs >= startMs) catchTimesMs.add(startedMs);
      for (var index = 0; index < samples; index++) {
        final timeMs = startedMs + durationMs * index / (samples - 1);
        if (timeMs < startMs || timeMs > endMs) continue;
        // ストローク境界の重複点(前のストロークの末尾)は落とす。
        if (times.isNotEmpty && timeMs <= times.last) continue;
        times.add(timeMs);
        speeds.add(math.max(
          0.0,
          trace.baseSpeedMetersPerSecond + trace.relativeSpeeds[index],
        ));
      }
    }
    if (times.length < 2) return null;

    var minSpeed = double.infinity;
    var maxSpeed = -double.infinity;
    var sum = 0.0;
    for (final speed in speeds) {
      if (speed < minSpeed) minSpeed = speed;
      if (speed > maxSpeed) maxSpeed = speed;
      sum += speed;
    }
    return StrokeSpeedTraceWindow(
      timesMs: Float64List.fromList(times),
      speeds: Float64List.fromList(speeds),
      catchTimesMs: catchTimesMs,
      startMs: startMs.toDouble(),
      endMs: endMs.toDouble(),
      minSpeed: minSpeed,
      maxSpeed: maxSpeed,
      meanSpeed: sum / speeds.length,
    );
  }
}
