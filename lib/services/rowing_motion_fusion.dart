import 'dart:collection';
import 'dart:math' as math;

import '../config/stroke_rate_config.dart';
import '../models/shared_stroke_trace.dart';
import 'stroke_rate_analyzer.dart';
import 'stroke_speed_trace.dart';

/// 端末座標系の角速度サンプル [rad/s]。
class RowingGyroscopeSample {
  final DateTime timestamp;
  final double x;
  final double y;
  final double z;

  const RowingGyroscopeSample({
    required this.timestamp,
    required this.x,
    required this.y,
    required this.z,
  });
}

/// 重力を含む加速度。ジャイロを水面鉛直軸へ射影するためだけに使う。
class RowingGravitySample {
  final DateTime timestamp;
  final double x;
  final double y;
  final double z;

  const RowingGravitySample({
    required this.timestamp,
    required this.x,
    required this.y,
    required this.z,
  });
}

enum RowingMotionQuality { unavailable, degraded, good }

/// 直近の完全な1ストロークと、現在のIMU/GNSS融合状態。
class RowingMotionMetrics {
  final DateTime calculatedAt;
  final DateTime latestStrokeBoundary;
  final RowingMotionQuality quality;
  final double confidence;
  final double spm;
  final double fusedSpeedMetersPerSecond;
  final double fusedSpeedAccuracyMetersPerSecond;
  final double? fusedHeadingDegrees;

  /// 1ストロークで進んだ距離。GPS低周波艇速とIMU内速度変動の積分値。
  final double distancePerStrokeMeters;

  /// キャッチ直後の最大艇速低下量。
  final double catchSpeedLossMetersPerSecond;

  /// ドライブ後半(中盤から推定フィニッシュまで)の艇速増加量。負なら失速。
  final double lateDriveSpeedGainMetersPerSecond;

  /// フィニッシュの艇速を、リカバリーを挟んで次のキャッチまで何割保ったか。0〜1。
  final double recoverySpeedRetention;

  final double strokeSpeedRangeMetersPerSecond;
  final double strokeDurationSeconds;
  final double finishPhaseFraction;
  final int accelerometerSampleCount;
  final int gyroscopeSampleCount;

  const RowingMotionMetrics({
    required this.calculatedAt,
    required this.latestStrokeBoundary,
    required this.quality,
    required this.confidence,
    required this.spm,
    required this.fusedSpeedMetersPerSecond,
    required this.fusedSpeedAccuracyMetersPerSecond,
    required this.fusedHeadingDegrees,
    required this.distancePerStrokeMeters,
    required this.catchSpeedLossMetersPerSecond,
    required this.lateDriveSpeedGainMetersPerSecond,
    required this.recoverySpeedRetention,
    required this.strokeSpeedRangeMetersPerSecond,
    required this.strokeDurationSeconds,
    required this.finishPhaseFraction,
    required this.accelerometerSampleCount,
    required this.gyroscopeSampleCount,
  });

  Map<String, dynamic> toDiagnosticDetails() => {
        'quality': quality.name,
        'confidence': confidence,
        'spm': spm,
        'fusedSpeedMps': fusedSpeedMetersPerSecond,
        'fusedSpeedAccuracyMps': fusedSpeedAccuracyMetersPerSecond,
        if (fusedHeadingDegrees != null) 'fusedHeadingDeg': fusedHeadingDegrees,
        'distancePerStrokeM': distancePerStrokeMeters,
        'catchSpeedLossMps': catchSpeedLossMetersPerSecond,
        'lateDriveSpeedGainMps': lateDriveSpeedGainMetersPerSecond,
        'recoverySpeedRetention': recoverySpeedRetention,
        'strokeSpeedRangeMps': strokeSpeedRangeMetersPerSecond,
        'strokeDurationSec': strokeDurationSeconds,
        'finishPhaseFraction': finishPhaseFraction,
        'accelerometerSamples': accelerometerSampleCount,
        'gyroscopeSamples': gyroscopeSampleCount,
      };
}

/// 固定されたスマホのIMUとGNSSを、ローイングの周期運動に合わせて融合する。
///
/// 絶対位置をIMUだけで作らない。GPS艇速をドリフトしない低周波基準とし、
/// 1ストローク内で平均0になる加速度積分だけを高周波成分として加える。
/// ジャイロは重力軸周りの相対回頭にだけ使い、GNSSごとに積分をリセットする。
class RowingMotionFusion {
  final StrokeRateAnalyzer _strokeAnalyzer;
  final Queue<StrokeRateSample> _accelerometer = Queue();
  final Queue<RowingGyroscopeSample> _gyroscope = Queue();

  /// 表示用の連続波形。**判定には使わない。**
  /// グラフを出さない運用では [setTraceEnabled] で丸ごと止める。
  final StrokeSpeedTraceRecorder _trace = StrokeSpeedTraceRecorder();
  bool _traceEnabled = false;

  RowingGravitySample? _gravity;
  DateTime? _lastGyroscopeAt;
  double _yawSinceGnssRadians = 0;
  DateTime? _lastGnssAt;
  double? _baseSpeed;
  double? _baseHeading;
  double? _lastReliableRelativeVelocity;
  DateTime? _lastAnalyzedStrokeBoundary;

  RowingMotionFusion({StrokeRateAnalyzer? strokeAnalyzer})
      : _strokeAnalyzer = strokeAnalyzer ?? StrokeRateAnalyzer();

  void reset() {
    _accelerometer.clear();
    _gyroscope.clear();
    _gravity = null;
    _lastGyroscopeAt = null;
    _yawSinceGnssRadians = 0;
    _lastGnssAt = null;
    _baseSpeed = null;
    _baseHeading = null;
    _lastReliableRelativeVelocity = null;
    _lastAnalyzedStrokeBoundary = null;
    _trace.reset();
  }

  /// グラフ表示・監視共有のどちらかが必要なときだけ true。
  /// false のあいだは1サンプルごとの積分もリングバッファも動かさない。
  void setTraceEnabled(bool enabled) {
    if (_traceEnabled == enabled) return;
    _traceEnabled = enabled;
    if (!enabled) _trace.reset();
  }

  void addUserAcceleration(StrokeRateSample sample) {
    if (!_finite3(sample.x, sample.y, sample.z)) return;
    _accelerometer.addLast(sample);
    _trim(_accelerometer, sample.timestamp);
    if (_traceEnabled) {
      _trace.addSample(
        timestamp: sample.timestamp,
        x: sample.x,
        y: sample.y,
        z: sample.z,
      );
    }
  }

  void addGravity(RowingGravitySample sample) {
    if (!_finite3(sample.x, sample.y, sample.z)) return;
    final magnitude = math.sqrt(
      sample.x * sample.x + sample.y * sample.y + sample.z * sample.z,
    );
    // 急な衝撃中の値を鉛直方向として採用しない。艇の前後加速度が
    // そのまま鉛直軸を傾けないよう約1秒で低域化する。
    if (magnitude < 7.0 || magnitude > 13.0) return;
    final previous = _gravity;
    if (previous == null) {
      _gravity = sample;
      return;
    }
    final dt = sample.timestamp.difference(previous.timestamp).inMicroseconds /
        Duration.microsecondsPerSecond;
    if (dt <= 0 || dt > 0.5) {
      _gravity = sample;
      return;
    }
    final alpha = 1 - math.exp(-dt / 1.0);
    _gravity = RowingGravitySample(
      timestamp: sample.timestamp,
      x: previous.x + alpha * (sample.x - previous.x),
      y: previous.y + alpha * (sample.y - previous.y),
      z: previous.z + alpha * (sample.z - previous.z),
    );
  }

  void addGyroscope(RowingGyroscopeSample sample) {
    if (!_finite3(sample.x, sample.y, sample.z)) return;
    _gyroscope.addLast(sample);
    _trim(_gyroscope, sample.timestamp);

    final previous = _lastGyroscopeAt;
    _lastGyroscopeAt = sample.timestamp;
    final gravity = _gravity;
    if (previous == null || gravity == null) return;
    final dt = sample.timestamp.difference(previous).inMicroseconds /
        Duration.microsecondsPerSecond;
    if (dt <= 0 || dt > 0.25) return;
    final gLength = math.sqrt(
      gravity.x * gravity.x + gravity.y * gravity.y + gravity.z * gravity.z,
    );
    if (gLength < 1) return;
    final yawRate =
        (sample.x * gravity.x + sample.y * gravity.y + sample.z * gravity.z) /
            gLength;
    // 艇の通常回頭を大きく超える衝撃は方位へ積分しない。
    if (yawRate.abs() <= 1.2) _yawSinceGnssRadians += yawRate * dt;
  }

  /// 新しいGNSS艇速・進行方位をドリフトしない基準として取り込む。
  void observeGnss({
    required DateTime timestamp,
    required double speedMetersPerSecond,
    required double accuracyMeters,
    double? headingDegrees,
  }) {
    if (!speedMetersPerSecond.isFinite || speedMetersPerSecond < 0) return;
    final safeAccuracy =
        accuracyMeters.isFinite && accuracyMeters > 0 ? accuracyMeters : 25.0;
    // 精度が良いほど速く追従するが、ストローク内のGNSS速度揺れを基準へ
    // そのまま写さない。停止への遷移だけは遅らせない。
    final alpha = speedMetersPerSecond < 0.4
        ? 0.75
        : (0.58 - safeAccuracy * 0.018).clamp(0.18, 0.48).toDouble();
    _baseSpeed = _baseSpeed == null
        ? speedMetersPerSecond
        : _baseSpeed! + alpha * (speedMetersPerSecond - _baseSpeed!);
    if (_traceEnabled) _trace.setBaseSpeed(_baseSpeed!);
    _lastGnssAt = timestamp;
    if (headingDegrees != null &&
        headingDegrees.isFinite &&
        headingDegrees >= 0 &&
        headingDegrees < 360 &&
        speedMetersPerSecond >= 0.6) {
      _baseHeading = headingDegrees;
      _yawSinceGnssRadians = 0;
    }
  }

  RowingMotionMetrics? analyze({DateTime? now}) {
    final calculatedAt = now ?? DateTime.now();
    final estimate = _strokeAnalyzer.estimate(_accelerometer.toList());
    final baseSpeed = _baseSpeed;
    if (estimate == null || baseSpeed == null) return null;

    final start = estimate.previousStrokeBoundary;
    final end = estimate.latestStrokeBoundary;
    final strokeSamples = _accelerometer
        .where((sample) =>
            !sample.timestamp.isBefore(start) && !sample.timestamp.isAfter(end))
        .toList(growable: false);
    if (strokeSamples.length < 20) return null;
    final duration =
        end.difference(start).inMicroseconds / Duration.microsecondsPerSecond;
    if (duration <= 0 || duration > 5) return null;

    final projectedAcceleration = strokeSamples
        .map((sample) =>
            sample.x * estimate.longitudinalAxisX +
            sample.y * estimate.longitudinalAxisY +
            sample.z * estimate.longitudinalAxisZ)
        .toList(growable: false);
    final bias = _timeWeightedMean(projectedAcceleration, strokeSamples);
    if (_traceEnabled) {
      // 連続波形は毎サンプル進むが、艇長軸とバイアスはここでしか
      // 求まらない。1秒ごとに最新の推定値へ入れ替える。
      _trace.setLongitudinalAxis(
        x: estimate.longitudinalAxisX,
        y: estimate.longitudinalAxisY,
        z: estimate.longitudinalAxisZ,
        bias: bias,
      );
      _trace.noteStrokeBoundary(start);
      _trace.noteStrokeBoundary(end);
    }
    // スマホ固定部の微小振動で加速度0交差が増えないようにする。
    // 遅延を招く長いローパスは使わず、50Hzで5点だけ平滑化する。
    final acceleration = _movingAverage(
      projectedAcceleration.map((value) => value - bias).toList(),
      radius: 2,
    );
    final relativeVelocity = List<double>.filled(strokeSamples.length, 0);
    for (var index = 1; index < strokeSamples.length; index++) {
      final dt = strokeSamples[index]
              .timestamp
              .difference(strokeSamples[index - 1].timestamp)
              .inMicroseconds /
          Duration.microsecondsPerSecond;
      if (dt <= 0 || dt > 0.25) continue;
      relativeVelocity[index] = relativeVelocity[index - 1] +
          0.5 * (acceleration[index - 1] + acceleration[index]) * dt;
    }
    // 数値積分の残差を端点0の直線として除去し、各ストロークを閉じる。
    final endDrift = relativeVelocity.last;
    for (var index = 0; index < relativeVelocity.length; index++) {
      final fraction =
          strokeSamples[index].timestamp.difference(start).inMicroseconds /
              math.max(1, end.difference(start).inMicroseconds);
      relativeVelocity[index] -= endDrift * fraction;
    }
    final velocityMean = _timeWeightedMean(relativeVelocity, strokeSamples);
    for (var index = 0; index < relativeVelocity.length; index++) {
      relativeVelocity[index] -= velocityMean;
    }

    final firstQuarterEnd = _phaseIndex(strokeSamples, start, duration, 0.25);
    var catchMinimumIndex = 0;
    for (var index = 1; index <= firstQuarterEnd; index++) {
      if (relativeVelocity[index] < relativeVelocity[catchMinimumIndex]) {
        catchMinimumIndex = index;
      }
    }
    final catchMinimum = relativeVelocity[catchMinimumIndex];
    final finishIndex = _estimateFinishIndex(
      samples: strokeSamples,
      acceleration: acceleration,
      relativeVelocity: relativeVelocity,
      start: start,
      duration: duration,
    );
    final middleIndex =
        catchMinimumIndex + ((finishIndex - catchMinimumIndex) ~/ 2);
    final finishVelocity = relativeVelocity[finishIndex];
    final endingVelocity = relativeVelocity.last;
    final range =
        relativeVelocity.reduce(math.max) - relativeVelocity.reduce(math.min);
    final catchLoss = math.max(0.0, relativeVelocity.first - catchMinimum);
    // 負値は隠さず「ドライブ後半失速」としてUIへ渡す。
    final lateDriveGain = finishVelocity - relativeVelocity[middleIndex];
    final recoveryRetention = range <= 0.05
        ? 1.0
        : (1 - (finishVelocity - endingVelocity) / range)
            .clamp(0.0, 1.0)
            .toDouble();

    var distance = 0.0;
    for (var index = 1; index < strokeSamples.length; index++) {
      final dt = strokeSamples[index]
              .timestamp
              .difference(strokeSamples[index - 1].timestamp)
              .inMicroseconds /
          Duration.microsecondsPerSecond;
      if (dt <= 0 || dt > 0.25) continue;
      final previousSpeed =
          math.max(0.0, baseSpeed + relativeVelocity[index - 1]);
      final currentSpeed = math.max(0.0, baseSpeed + relativeVelocity[index]);
      distance += 0.5 * (previousSpeed + currentSpeed) * dt;
    }

    final latestRelative = _currentRelativeVelocity(
      estimate: estimate,
      completeStrokeBias: bias,
      maximumMagnitude: math.max(0.5, range * 1.5),
    );
    if (latestRelative != null) _lastReliableRelativeVelocity = latestRelative;
    final relativeForSpeed =
        latestRelative ?? _lastReliableRelativeVelocity ?? 0;
    final sampleCoverage =
        (strokeSamples.length / (duration * 50)).clamp(0.0, 1.0).toDouble();
    final gyroCount = _gyroscope
        .where((sample) =>
            !sample.timestamp.isBefore(start) && !sample.timestamp.isAfter(end))
        .length;
    final gyroCoverage = (gyroCount / (duration * 50)).clamp(0.0, 1.0);
    final confidence = (estimate.confidence * 0.78 +
            sampleCoverage * 0.14 +
            gyroCoverage * 0.08)
        .clamp(0.0, 1.0)
        .toDouble();
    final quality = confidence >= 0.72 && sampleCoverage >= 0.75
        ? RowingMotionQuality.good
        : RowingMotionQuality.degraded;
    final speedAccuracy = (1.45 - confidence).clamp(0.45, 1.4).toDouble();
    final heading = _fusedHeading(calculatedAt);
    _lastAnalyzedStrokeBoundary = end;

    return RowingMotionMetrics(
      calculatedAt: calculatedAt,
      latestStrokeBoundary: end,
      quality: quality,
      confidence: confidence,
      spm: estimate.spm,
      fusedSpeedMetersPerSecond: math.max(0.0, baseSpeed + relativeForSpeed),
      fusedSpeedAccuracyMetersPerSecond: speedAccuracy,
      fusedHeadingDegrees: heading,
      distancePerStrokeMeters: distance,
      catchSpeedLossMetersPerSecond: catchLoss,
      lateDriveSpeedGainMetersPerSecond: lateDriveGain,
      recoverySpeedRetention: recoveryRetention,
      strokeSpeedRangeMetersPerSecond: range,
      strokeDurationSeconds: duration,
      finishPhaseFraction: strokeSamples[finishIndex]
              .timestamp
              .difference(start)
              .inMicroseconds /
          Duration.microsecondsPerSecond /
          duration,
      accelerometerSampleCount: strokeSamples.length,
      gyroscopeSampleCount: gyroCount,
    );
  }

  bool get analyzedNewStroke => _lastAnalyzedStrokeBoundary != null;

  /// 心電図のように流すグラフ1画面ぶん。**表示専用。**
  ///
  /// 描画のたびに呼ばれるため、状態は一切変えず、リングから切り出すだけ。
  StrokeSpeedTraceWindow? traceWindow({
    required DateTime now,
    required double windowSeconds,
  }) {
    if (!_traceEnabled) return null;
    return _trace.window(now: now, windowSeconds: windowSeconds);
  }

  /// 直近の完全な1ストロークを、監視端末へ送れる形へまとめる。
  ///
  /// 波形が切り出せない(欠測・軸未確定)ときは null を返す。
  /// 平均艇速はストローク距離÷周期で、そのストロークの実測平均になる。
  SharedStrokeTrace? buildSharedStrokeTrace(RowingMotionMetrics metrics) {
    if (!_traceEnabled) return null;
    if (metrics.strokeDurationSeconds <= 0) return null;
    final end = metrics.latestStrokeBoundary;
    final start = end.subtract(Duration(
      microseconds: (metrics.strokeDurationSeconds *
              Duration.microsecondsPerSecond)
          .round(),
    ));
    final waveform = _trace.resampleStroke(start: start, end: end);
    if (waveform == null) return null;
    final meanSpeed =
        metrics.distancePerStrokeMeters / metrics.strokeDurationSeconds;
    if (!meanSpeed.isFinite || meanSpeed < 0) return null;
    return SharedStrokeTrace(
      strokeStartedAt: start,
      strokeDuration: Duration(
        milliseconds:
            (metrics.strokeDurationSeconds * Duration.millisecondsPerSecond)
                .round(),
      ),
      baseSpeedMetersPerSecond: meanSpeed,
      relativeSpeeds: waveform,
      spm: metrics.spm,
      confidence: metrics.confidence,
      distancePerStrokeMeters: metrics.distancePerStrokeMeters,
      catchSpeedLossMetersPerSecond: metrics.catchSpeedLossMetersPerSecond,
      lateDriveSpeedGainMetersPerSecond:
          metrics.lateDriveSpeedGainMetersPerSecond,
      recoverySpeedRetention: metrics.recoverySpeedRetention,
      finishPhaseFraction: metrics.finishPhaseFraction,
    );
  }

  double? _currentRelativeVelocity({
    required StrokeRateEstimate estimate,
    required double completeStrokeBias,
    required double maximumMagnitude,
  }) {
    final start = estimate.latestStrokeBoundary;
    final samples = _accelerometer
        .where((sample) => !sample.timestamp.isBefore(start))
        .toList(growable: false);
    if (samples.length < 2) return null;
    var velocity = 0.0;
    for (var index = 1; index < samples.length; index++) {
      final dt = samples[index]
              .timestamp
              .difference(samples[index - 1].timestamp)
              .inMicroseconds /
          Duration.microsecondsPerSecond;
      if (dt <= 0 || dt > 0.25) return null;
      final a0 = samples[index - 1].x * estimate.longitudinalAxisX +
          samples[index - 1].y * estimate.longitudinalAxisY +
          samples[index - 1].z * estimate.longitudinalAxisZ -
          completeStrokeBias;
      final a1 = samples[index].x * estimate.longitudinalAxisX +
          samples[index].y * estimate.longitudinalAxisY +
          samples[index].z * estimate.longitudinalAxisZ -
          completeStrokeBias;
      velocity += 0.5 * (a0 + a1) * dt;
    }
    return velocity.clamp(-maximumMagnitude, maximumMagnitude).toDouble();
  }

  double? _fusedHeading(DateTime now) {
    final heading = _baseHeading;
    final lastGnss = _lastGnssAt;
    if (heading == null || lastGnss == null) return null;
    if (now.difference(lastGnss) > const Duration(seconds: 5)) return null;
    // センサー角速度は右手系（+鉛直軸を見て反時計回りが正）、航法方位は
    // 北基準で時計回りが正なので符号を反転する。
    final result = heading - _yawSinceGnssRadians * 180 / math.pi;
    return ((result % 360) + 360) % 360;
  }

  int _phaseIndex(
    List<StrokeRateSample> samples,
    DateTime start,
    double duration,
    double fraction,
  ) {
    final target = start.add(Duration(
      microseconds:
          (duration * fraction * Duration.microsecondsPerSecond).round(),
    ));
    var index = 0;
    while (index + 1 < samples.length &&
        samples[index + 1].timestamp.isBefore(target)) {
      index++;
    }
    return index.clamp(0, samples.length - 1);
  }

  int _estimateFinishIndex({
    required List<StrokeRateSample> samples,
    required List<double> acceleration,
    required List<double> relativeVelocity,
    required DateTime start,
    required double duration,
  }) {
    final crossingStart = _phaseIndex(samples, start, duration, 0.12);
    final crossingEnd = _phaseIndex(samples, start, duration, 0.68);
    // ドライブ中の正の加速が、連続して負に転じた最初の点を優先。
    // 単発ノイズを0交差と誤認しないよう次の2点も確認する。
    for (var index = crossingStart + 1; index + 2 <= crossingEnd; index++) {
      if (acceleration[index - 1] > 0.03 &&
          acceleration[index] <= 0 &&
          acceleration[index + 1] <= 0 &&
          acceleration[index + 2] <= 0) {
        return index;
      }
    }

    // 0交差が不鮮明な時だけ、回復期に入る前の最大速度を使う。
    final fallbackStart = _phaseIndex(samples, start, duration, 0.20);
    final fallbackEnd = _phaseIndex(samples, start, duration, 0.58);
    var result = fallbackStart;
    for (var index = fallbackStart + 1; index <= fallbackEnd; index++) {
      if (relativeVelocity[index] > relativeVelocity[result]) result = index;
    }
    return result;
  }

  List<double> _movingAverage(List<double> values, {required int radius}) {
    if (values.length < 3 || radius <= 0) return values;
    return List<double>.generate(values.length, (index) {
      final first = math.max(0, index - radius);
      final last = math.min(values.length - 1, index + radius);
      var sum = 0.0;
      for (var sample = first; sample <= last; sample++) {
        sum += values[sample];
      }
      return sum / (last - first + 1);
    }, growable: false);
  }

  double _timeWeightedMean(
    List<double> values,
    List<StrokeRateSample> samples,
  ) {
    if (values.length < 2 || values.length != samples.length) {
      return values.isEmpty
          ? 0
          : values.reduce((a, b) => a + b) / values.length;
    }
    var integral = 0.0;
    var duration = 0.0;
    for (var index = 1; index < values.length; index++) {
      final dt = samples[index]
              .timestamp
              .difference(samples[index - 1].timestamp)
              .inMicroseconds /
          Duration.microsecondsPerSecond;
      if (dt <= 0 || dt > 0.25) continue;
      integral += 0.5 * (values[index - 1] + values[index]) * dt;
      duration += dt;
    }
    return duration > 0 ? integral / duration : 0;
  }

  void _trim<T>(Queue<T> queue, DateTime latest) {
    while (queue.isNotEmpty) {
      final timestamp = switch (queue.first) {
        StrokeRateSample sample => sample.timestamp,
        RowingGyroscopeSample sample => sample.timestamp,
        _ => latest,
      };
      if (latest.difference(timestamp) <=
          const Duration(seconds: spmWindowSec)) {
        break;
      }
      queue.removeFirst();
    }
  }

  bool _finite3(double x, double y, double z) =>
      x.isFinite && y.isFinite && z.isFinite;
}

/// 位置差分とIMU融合艇速を組み合わせる距離積算器。
///
/// GNSS座標だけのジグザグと、艇速だけの積分ドリフトの双方を避ける。
class RowingDistanceIntegrator {
  DateTime? _lastTimestamp;
  double? _lastSpeed;

  void reset() {
    _lastTimestamp = null;
    _lastSpeed = null;
  }

  double add({
    required DateTime timestamp,
    required double coordinateDistanceMeters,
    required double speedMetersPerSecond,
    double? motionConfidence,
    required bool moving,
  }) {
    final previousTimestamp = _lastTimestamp;
    final previousSpeed = _lastSpeed;
    _lastTimestamp = timestamp;
    _lastSpeed = speedMetersPerSecond;
    if (!moving ||
        previousTimestamp == null ||
        previousSpeed == null ||
        !coordinateDistanceMeters.isFinite ||
        coordinateDistanceMeters < 0 ||
        !speedMetersPerSecond.isFinite ||
        speedMetersPerSecond < 0) {
      return 0;
    }
    final dt = timestamp.difference(previousTimestamp).inMicroseconds /
        Duration.microsecondsPerSecond;
    if (dt <= 0 || dt > 2.5) return coordinateDistanceMeters;
    final speedDistance = 0.5 * (previousSpeed + speedMetersPerSecond) * dt;
    if (!speedDistance.isFinite || speedDistance < 0) {
      return coordinateDistanceMeters;
    }
    final weight = motionConfidence == null
        ? 0.0
        : ((motionConfidence - imuNavigationMinimumConfidence) /
                (1 - imuNavigationMinimumConfidence) *
                0.55)
            .clamp(0.0, 0.55)
            .toDouble();
    return coordinateDistanceMeters * (1 - weight) + speedDistance * weight;
  }
}
