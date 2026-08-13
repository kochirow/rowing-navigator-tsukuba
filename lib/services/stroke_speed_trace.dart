import 'dart:math' as math;
import 'dart:typed_data';

import '../config/stroke_trace_config.dart';

/// グラフ1画面ぶんの艇速波形。**表示専用**で、安全判定には一切使わない。
///
/// 時刻はエポックミリ秒の double。描画側は「窓の左端＝[startMs]、
/// 右端＝[endMs]」として横位置を決める。データが右端まで無い場合は
/// そこで線が途切れる。空白を勝手に埋めない(原則6)。
class StrokeSpeedTraceWindow {
  /// 各点のエポックミリ秒(昇順)。
  final Float64List timesMs;

  /// 各点の艇速 [m/s]。GNSSの低周波艇速に、ストローク内変動を足した値。
  final Float64List speeds;

  /// 窓に含まれるキャッチ(ストローク境界)のエポックミリ秒。
  final List<double> catchTimesMs;

  final double startMs;
  final double endMs;

  /// 窓内の艇速の実測範囲。縦軸の下限レンジは描画側で確保する。
  final double minSpeed;
  final double maxSpeed;

  /// 窓内の平均艇速 [m/s]。基準線として描く。
  final double meanSpeed;

  const StrokeSpeedTraceWindow({
    required this.timesMs,
    required this.speeds,
    required this.catchTimesMs,
    required this.startMs,
    required this.endMs,
    required this.minSpeed,
    required this.maxSpeed,
    required this.meanSpeed,
  });

  bool get isEmpty => timesMs.isEmpty;

  int get length => timesMs.length;

  /// 実データが右端からどれだけ古いか [秒]。途切れの可視化に使う。
  double get trailingGapSeconds =>
      isEmpty ? double.infinity : (endMs - timesMs[timesMs.length - 1]) / 1000;
}

/// 加速度から連続的な艇速波形を作り、直近数秒だけを保持するリング。
///
/// **絶対位置も安全判定も作らない。** GNSS艇速を基準に、ストローク周期の
/// 変動だけを重ねて「見せる」ためのもの。[RowingMotionFusion] が1秒ごとに
/// 行う厳密な1ストローク解析とは別経路で、こちらは1サンプルごとに
/// O(1) で進む(描画を滑らかにするため)。
///
/// 直流の扱いは2段構え。
///   1. 積分そのものは [strokeTraceHighPassSeconds] で漏らし、発散を止める
///   2. 切り出し時に窓平均を引き、窓の平均艇速をGNSS艇速に一致させる
/// これにより、加速度バイアスが残っていても「平均はGNSS、変動はIMU」になる。
class StrokeSpeedTraceRecorder {
  final int _capacity;
  final Float64List _timesMs;
  final Float64List _relative;
  final Float64List _base;
  int _start = 0;
  int _count = 0;

  final List<double> _catchTimesMs = <double>[];

  double? _axisX;
  double? _axisY;
  double? _axisZ;
  double _bias = 0;
  double _baseSpeed = 0;
  double _velocity = 0;
  DateTime? _lastSampleAt;
  DateTime? _lastStoredAt;

  StrokeSpeedTraceRecorder({int? capacity})
      : _capacity =
            capacity ?? (strokeTraceBufferSeconds * strokeTraceSampleHz + 8),
        _timesMs = Float64List(
          capacity ?? (strokeTraceBufferSeconds * strokeTraceSampleHz + 8),
        ),
        _relative = Float64List(
          capacity ?? (strokeTraceBufferSeconds * strokeTraceSampleHz + 8),
        ),
        _base = Float64List(
          capacity ?? (strokeTraceBufferSeconds * strokeTraceSampleHz + 8),
        );

  int get length => _count;

  bool get hasAxis => _axisX != null;

  void reset() {
    _start = 0;
    _count = 0;
    _catchTimesMs.clear();
    _axisX = null;
    _axisY = null;
    _axisZ = null;
    _bias = 0;
    _baseSpeed = 0;
    _velocity = 0;
    _lastSampleAt = null;
    _lastStoredAt = null;
  }

  /// 艇の長軸と、その軸上での加速度バイアス。
  /// [StrokeRateAnalyzer] が窓ごとに推定した値を1秒ごとに受け取る。
  void setLongitudinalAxis({
    required double x,
    required double y,
    required double z,
    required double bias,
  }) {
    if (!x.isFinite || !y.isFinite || !z.isFinite || !bias.isFinite) return;
    final length = math.sqrt(x * x + y * y + z * z);
    if (length < 1e-6) return;
    final previousX = _axisX;
    // 軸の符号が反転したら、それまでの積分値は逆向きの速度になる。
    // 引き継がずに0へ戻す(数秒で再び立ち上がる)。
    if (previousX != null &&
        (previousX * x + _axisY! * y + _axisZ! * z) / length < 0) {
      _velocity = 0;
    }
    _axisX = x / length;
    _axisY = y / length;
    _axisZ = z / length;
    _bias = bias;
  }

  /// GNSSの低周波艇速 [m/s]。窓の平均艇速はこの値になる。
  void setBaseSpeed(double speedMetersPerSecond) {
    if (!speedMetersPerSecond.isFinite || speedMetersPerSecond < 0) return;
    _baseSpeed = speedMetersPerSecond;
  }

  /// キャッチ(ストローク境界)。グラフの縦線として出す。
  void noteStrokeBoundary(DateTime timestamp) {
    final ms = timestamp.millisecondsSinceEpoch.toDouble();
    if (_catchTimesMs.isNotEmpty && (_catchTimesMs.last - ms).abs() < 1) return;
    if (_catchTimesMs.isNotEmpty && ms < _catchTimesMs.last) return;
    _catchTimesMs.add(ms);
    while (_catchTimesMs.length > 16) {
      _catchTimesMs.removeAt(0);
    }
  }

  /// 重力を除いた加速度サンプル。50Hzで呼ばれる想定。
  ///
  /// 積分は全サンプルで進め、リングへは [strokeTraceSampleHz] へ間引いて
  /// 入れる。軸が未確定のあいだは何も記録しない(向きの分からない
  /// 加速度を艇速として見せない)。
  void addSample({
    required DateTime timestamp,
    required double x,
    required double y,
    required double z,
  }) {
    final axisX = _axisX;
    if (axisX == null || !x.isFinite || !y.isFinite || !z.isFinite) return;
    final previous = _lastSampleAt;
    _lastSampleAt = timestamp;
    if (previous == null) return;
    final dt = timestamp.difference(previous).inMicroseconds /
        Duration.microsecondsPerSecond;
    // 欠測をまたいで積分しない。再開時は速度を落として立ち上げ直す。
    if (dt <= 0 || dt > 0.25) {
      _velocity = 0;
      _lastStoredAt = null;
      return;
    }
    final acceleration = x * axisX + y * _axisY! + z * _axisZ! - _bias;
    _velocity += acceleration * dt;
    _velocity -= _velocity * (dt / strokeTraceHighPassSeconds);
    if (!_velocity.isFinite) {
      _velocity = 0;
      return;
    }

    final storedAt = _lastStoredAt;
    final minimumGapMs = 1000 / strokeTraceSampleHz - 4;
    if (storedAt != null &&
        timestamp.difference(storedAt).inMilliseconds < minimumGapMs) {
      return;
    }
    _lastStoredAt = timestamp;
    _push(
      timestamp.millisecondsSinceEpoch.toDouble(),
      _velocity,
      _baseSpeed,
    );
  }

  void _push(double timeMs, double relative, double base) {
    final index = (_start + _count) % _capacity;
    _timesMs[index] = timeMs;
    _relative[index] = relative;
    _base[index] = base;
    if (_count < _capacity) {
      _count++;
    } else {
      _start = (_start + 1) % _capacity;
    }
  }

  int _indexAt(int offset) => (_start + offset) % _capacity;

  /// 窓を切り出す。データが1点以下しかない場合は null。
  ///
  /// [nowMs] は右端の時刻。航行中は現在時刻を渡す。
  StrokeSpeedTraceWindow? window({
    required DateTime now,
    required double windowSeconds,
  }) {
    if (_count < 2) return null;
    final endMs = now.millisecondsSinceEpoch.toDouble();
    final span = windowSeconds.clamp(
      strokeTraceMinimumWindowSeconds,
      strokeTraceMaximumWindowSeconds,
    );
    final startMs = endMs - span * 1000;

    var first = -1;
    var last = -1;
    for (var offset = 0; offset < _count; offset++) {
      final index = _indexAt(offset);
      final timeMs = _timesMs[index];
      if (timeMs < startMs || timeMs > endMs) continue;
      if (first < 0) first = offset;
      last = offset;
    }
    if (first < 0 || last <= first) return null;

    final length = last - first + 1;
    final times = Float64List(length);
    final speeds = Float64List(length);
    var relativeSum = 0.0;
    for (var offset = 0; offset < length; offset++) {
      final index = _indexAt(first + offset);
      times[offset] = _timesMs[index];
      relativeSum += _relative[index];
    }
    final relativeMean = relativeSum / length;
    var minSpeed = double.infinity;
    var maxSpeed = -double.infinity;
    var speedSum = 0.0;
    for (var offset = 0; offset < length; offset++) {
      final index = _indexAt(first + offset);
      // 窓平均を引くことで、この窓の平均艇速はGNSS艇速に一致する。
      final speed =
          math.max(0.0, _base[index] + _relative[index] - relativeMean);
      speeds[offset] = speed;
      speedSum += speed;
      if (speed < minSpeed) minSpeed = speed;
      if (speed > maxSpeed) maxSpeed = speed;
    }

    return StrokeSpeedTraceWindow(
      timesMs: times,
      speeds: speeds,
      catchTimesMs: _catchTimesMs
          .where((value) => value >= startMs && value <= endMs)
          .toList(growable: false),
      startMs: startMs,
      endMs: endMs,
      minSpeed: minSpeed,
      maxSpeed: maxSpeed,
      meanSpeed: speedSum / length,
    );
  }

  /// 1ストロークぶんの相対艇速を等間隔へ再標本化する。共有用。
  ///
  /// ストローク内の平均を0にして返すので、受け取った側は
  /// 「そのストロークの平均艇速 + この配列」で艇速曲線を復元できる。
  /// 区間がリングに収まっていない場合は null(欠測を捏造しない)。
  List<double>? resampleStroke({
    required DateTime start,
    required DateTime end,
    int samples = sharedStrokeWaveformSamples,
  }) {
    if (samples < 2 || _count < 2) return null;
    final startMs = start.millisecondsSinceEpoch.toDouble();
    final endMs = end.millisecondsSinceEpoch.toDouble();
    if (!(endMs > startMs)) return null;
    final firstStoredMs = _timesMs[_indexAt(0)];
    final lastStoredMs = _timesMs[_indexAt(_count - 1)];
    if (startMs < firstStoredMs || endMs > lastStoredMs) return null;

    // 区間内の実サンプルが疎すぎる場合は、形を保証できないので出さない。
    var covered = 0;
    for (var offset = 0; offset < _count; offset++) {
      final timeMs = _timesMs[_indexAt(offset)];
      if (timeMs >= startMs && timeMs <= endMs) covered++;
    }
    if (covered < samples ~/ 3) return null;

    final result = List<double>.filled(samples, 0);
    var cursor = 0;
    for (var index = 0; index < samples; index++) {
      final targetMs = startMs + (endMs - startMs) * index / (samples - 1);
      while (cursor + 1 < _count - 1 &&
          _timesMs[_indexAt(cursor + 1)] < targetMs) {
        cursor++;
      }
      final leftMs = _timesMs[_indexAt(cursor)];
      final rightMs = _timesMs[_indexAt(cursor + 1)];
      final left = _relative[_indexAt(cursor)];
      final right = _relative[_indexAt(cursor + 1)];
      final width = rightMs - leftMs;
      result[index] = width <= 0
          ? left
          : left + (right - left) * ((targetMs - leftMs) / width);
    }
    final mean = result.reduce((a, b) => a + b) / result.length;
    for (var index = 0; index < result.length; index++) {
      result[index] -= mean;
      if (!result[index].isFinite) return null;
    }
    return result;
  }
}

/// 表示する時間窓 [秒] を「直近2ストローク」から決める。
///
/// SPMが取れていないあいだは既定値へ縮退する。計測不能でグラフを消すのでは
/// なく、時間軸だけ固定して波形は出し続ける(原則1)。
double strokeTraceWindowSecondsFor({double? spm}) {
  if (spm == null || !spm.isFinite || spm <= 0) {
    return strokeTraceFallbackWindowSeconds;
  }
  final seconds = 60 / spm * strokeTraceStrokesOnScreen;
  if (!seconds.isFinite) return strokeTraceFallbackWindowSeconds;
  return seconds.clamp(
    strokeTraceMinimumWindowSeconds,
    strokeTraceMaximumWindowSeconds,
  );
}
