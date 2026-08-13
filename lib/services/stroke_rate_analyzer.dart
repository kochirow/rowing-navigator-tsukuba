import 'dart:math';

import '../config/stroke_rate_config.dart';

/// タイムスタンプ付きの、重力を除いた3軸加速度サンプル。
class StrokeRateSample {
  final DateTime timestamp;
  final double x;
  final double y;
  final double z;

  const StrokeRateSample({
    required this.timestamp,
    required this.x,
    required this.y,
    required this.z,
  });
}

/// 推定値と、今回の窓での信頼性。
class StrokeRateEstimate {
  final double spm;
  final double confidence;
  final int strokeCount;
  final double intervalCoefficientOfVariation;

  /// 艇の長軸として推定した端末座標系の単位ベクトル。
  /// 符号は、ストローク境界（キャッチ候補）が負の加速度になる向きへ揃える。
  final double longitudinalAxisX;
  final double longitudinalAxisY;
  final double longitudinalAxisZ;

  /// 直近2つの完全なストローク境界。艇速曲線の位相合わせに使う。
  final DateTime previousStrokeBoundary;
  final DateTime latestStrokeBoundary;

  const StrokeRateEstimate({
    required this.spm,
    required this.confidence,
    required this.strokeCount,
    required this.intervalCoefficientOfVariation,
    required this.longitudinalAxisX,
    required this.longitudinalAxisY,
    required this.longitudinalAxisZ,
    required this.previousStrokeBoundary,
    required this.latestStrokeBoundary,
  });
}

/// 艇に固定したスマートフォンの慣性センサからストロークレートを推定する。
///
/// ローイングでは、艇の長軸方向の加速度の谷がリカバリーからドライブへ
/// 切り替わるキャッチに対応する。端末の取付方向は艇ごとに異なるため、
/// 3軸の主運動軸を各窓で推定して符号付きの波形へ戻し、山・谷のうち周期が
/// より安定する方だけをストローク境界として使う。
class StrokeRateAnalyzer {
  /// 互換用の1軸・等間隔入力。実端末では [estimate] を使う。
  double? estimateSpm(List<double> samples, double sampleRateHz) {
    if (sampleRateHz <= 0 || !sampleRateHz.isFinite) return null;
    final converted = <StrokeRateSample>[];
    for (var index = 0; index < samples.length; index++) {
      final value = samples[index];
      if (!value.isFinite) continue;
      converted.add(StrokeRateSample(
        timestamp: DateTime.fromMicrosecondsSinceEpoch(
          (index * Duration.microsecondsPerSecond / sampleRateHz).round(),
        ),
        x: value,
        y: 0,
        z: 0,
      ));
    }
    return estimate(converted)?.spm;
  }

  /// 実際のセンサー時刻を使い、端末の向きに依存しないSPMを返す。
  ///
  /// 信頼性が足りない場合は、誤った値を出さずnullを返す。
  StrokeRateEstimate? estimate(List<StrokeRateSample> samples) {
    final valid = samples
        .where((sample) =>
            sample.x.isFinite && sample.y.isFinite && sample.z.isFinite)
        .toList(growable: false)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (valid.length < spmMinimumSamples) return null;
    final duration = valid.last.timestamp.difference(valid.first.timestamp);
    if (duration < const Duration(seconds: spmMinimumAnalysisSeconds)) {
      return null;
    }

    final highPassed = _removeSlowDrift(valid);
    final direction = _principalDirection(highPassed);
    if (direction == null) return null;
    final signal = _smooth(
      highPassed
          .map((sample) =>
              sample.x * direction.x +
              sample.y * direction.y +
              sample.z * direction.z)
          .toList(growable: false),
      valid,
    );
    final center = _median(signal);
    final mad = _median(signal.map((value) => (value - center).abs()).toList());
    final robustSpread = mad * 1.4826;
    if (!robustSpread.isFinite || robustSpread < spmMinimumSignalSpread) {
      return null;
    }

    final positive = _estimateFromExtrema(
      signal: signal,
      times: valid.map((sample) => sample.timestamp).toList(growable: false),
      center: center,
      robustSpread: robustSpread,
      positive: true,
    );
    final negative = _estimateFromExtrema(
      signal: signal,
      times: valid.map((sample) => sample.timestamp).toList(growable: false),
      center: center,
      robustSpread: robustSpread,
      positive: false,
    );
    final candidates = [positive, negative].whereType<_Candidate>().toList();
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => b.score.compareTo(a.score));
    final best = candidates.first;
    if (best.confidence < spmMinimumConfidence) return null;
    return StrokeRateEstimate(
      spm: best.spm,
      confidence: best.confidence,
      strokeCount: best.strokeCount,
      intervalCoefficientOfVariation: best.coefficientOfVariation,
      longitudinalAxisX: direction.x * (best.positive ? -1 : 1),
      longitudinalAxisY: direction.y * (best.positive ? -1 : 1),
      longitudinalAxisZ: direction.z * (best.positive ? -1 : 1),
      previousStrokeBoundary:
          valid[best.extremaIndices[best.extremaIndices.length - 2]].timestamp,
      latestStrokeBoundary: valid[best.extremaIndices.last].timestamp,
    );
  }

  List<_Vector> _removeSlowDrift(List<StrokeRateSample> samples) {
    var trend = _Vector(samples.first.x, samples.first.y, samples.first.z);
    var previousTime = samples.first.timestamp;
    final result = <_Vector>[];
    for (final sample in samples) {
      final raw = _Vector(sample.x, sample.y, sample.z);
      final dt = max(
        0.001,
        sample.timestamp.difference(previousTime).inMicroseconds /
            Duration.microsecondsPerSecond,
      );
      // 長い欠測の前後を同じ波形としてつながない。
      if (dt > spmMaximumSampleGapSeconds) trend = raw;
      final alpha = 1 - exp(-dt / spmDriftTimeConstantSeconds);
      trend = trend + (raw - trend) * alpha;
      result.add(raw - trend);
      previousTime = sample.timestamp;
    }
    return result;
  }

  _Vector? _principalDirection(List<_Vector> values) {
    var xx = 0.0;
    var xy = 0.0;
    var xz = 0.0;
    var yy = 0.0;
    var yz = 0.0;
    var zz = 0.0;
    for (final value in values) {
      xx += value.x * value.x;
      xy += value.x * value.y;
      xz += value.x * value.z;
      yy += value.y * value.y;
      yz += value.y * value.z;
      zz += value.z * value.z;
    }
    if (xx + yy + zz < spmMinimumSignalEnergy) return null;

    var direction = xx >= yy && xx >= zz
        ? const _Vector(1, 0, 0)
        : yy >= zz
            ? const _Vector(0, 1, 0)
            : const _Vector(0, 0, 1);
    // 3x3共分散行列のべき乗法。端末の固定方向を指定しなくても、
    // 最も再現性の高い艇体運動軸へ投影できる。
    for (var iteration = 0; iteration < 10; iteration++) {
      final next = _Vector(
        xx * direction.x + xy * direction.y + xz * direction.z,
        xy * direction.x + yy * direction.y + yz * direction.z,
        xz * direction.x + yz * direction.y + zz * direction.z,
      );
      final norm = next.length;
      if (norm <= 1e-9 || !norm.isFinite) return null;
      direction = next * (1 / norm);
    }
    return direction;
  }

  List<double> _smooth(List<double> signal, List<StrokeRateSample> samples) {
    final result = <double>[];
    var value = signal.first;
    var previousTime = samples.first.timestamp;
    for (var index = 0; index < signal.length; index++) {
      final dt = max(
        0.001,
        samples[index].timestamp.difference(previousTime).inMicroseconds /
            Duration.microsecondsPerSecond,
      );
      final alpha = 1 - exp(-dt / spmSmoothingTimeConstantSeconds);
      value += (signal[index] - value) * alpha;
      result.add(value);
      previousTime = samples[index].timestamp;
    }
    return result;
  }

  _Candidate? _estimateFromExtrema({
    required List<double> signal,
    required List<DateTime> times,
    required double center,
    required double robustSpread,
    required bool positive,
  }) {
    final extrema = <int>[];
    final threshold = robustSpread * spmExtremumThresholdFactor;
    final minGap = Duration(
      microseconds:
          (Duration.microsecondsPerSecond * 60 / spmMaximumRate).round(),
    );
    for (var index = 1; index < signal.length - 1; index++) {
      final current = signal[index];
      final isExtremum = positive
          ? current >= signal[index - 1] && current > signal[index + 1]
          : current <= signal[index - 1] && current < signal[index + 1];
      final enoughProminence = positive
          ? current - center >= threshold
          : center - current >= threshold;
      if (!isExtremum || !enoughProminence) continue;
      if (extrema.isNotEmpty &&
          times[index].difference(times[extrema.last]) < minGap) {
        final previous = extrema.last;
        final isMoreExtreme =
            positive ? current > signal[previous] : current < signal[previous];
        if (isMoreExtreme) extrema[extrema.length - 1] = index;
        continue;
      }
      extrema.add(index);
    }
    if (extrema.length < spmMinimumStrokeCount) return null;

    final rawIntervals = <double>[];
    for (var index = 1; index < extrema.length; index++) {
      final seconds = times[extrema[index]]
              .difference(times[extrema[index - 1]])
              .inMicroseconds /
          Duration.microsecondsPerSecond;
      if (seconds >= 60 / spmMaximumRate && seconds <= 60 / spmMinimumRate) {
        rawIntervals.add(seconds);
      }
    }
    if (rawIntervals.length < spmMinimumStrokeCount - 1) return null;
    final centerInterval = _median(rawIntervals);
    final filtered = rawIntervals
        .where((interval) =>
            (interval - centerInterval).abs() <=
            max(spmIntervalOutlierSeconds,
                centerInterval * spmIntervalOutlierFraction))
        .toList(growable: false);
    if (filtered.length < spmMinimumStrokeCount - 1) return null;
    final interval = _median(filtered);
    final mean = filtered.reduce((a, b) => a + b) / filtered.length;
    final variance = filtered
            .map((value) => (value - mean) * (value - mean))
            .reduce((a, b) => a + b) /
        filtered.length;
    final coefficientOfVariation = sqrt(variance) / mean;
    if (!coefficientOfVariation.isFinite ||
        coefficientOfVariation > spmMaximumIntervalCoefficientOfVariation) {
      return null;
    }
    final spm = 60 / interval;
    if (!spm.isFinite || spm < spmMinimumRate || spm > spmMaximumRate) {
      return null;
    }
    // 短い間隔でランダムな振動が続くだけでも、最小間隔の制約によって
    // 擬似的に整ったピーク列になることがある。推定周期だけ時間をずらした
    // 波形との相関を確認し、同じストローク波形が反復している時だけ採用する。
    final periodicity = _periodicityCorrelation(signal, times, interval);
    if (periodicity < spmMinimumPeriodicityCorrelation) return null;
    final countScore = min(1.0, filtered.length / spmConfidenceFullIntervals);
    final regularityScore = max(0.0,
        1 - coefficientOfVariation / spmMaximumIntervalCoefficientOfVariation);
    final amplitudeScore = min(1.0, robustSpread / spmConfidenceFullSpread);
    final confidence = 0.3 * countScore +
        0.4 * regularityScore +
        0.15 * amplitudeScore +
        0.15 * periodicity;
    return _Candidate(
      spm: spm,
      confidence: confidence,
      strokeCount: extrema.length,
      coefficientOfVariation: coefficientOfVariation,
      positive: positive,
      extremaIndices: List<int>.unmodifiable(extrema),
    );
  }

  double _periodicityCorrelation(
    List<double> signal,
    List<DateTime> times,
    double periodSeconds,
  ) {
    final mean = signal.reduce((a, b) => a + b) / signal.length;
    var right = 1;
    var dot = 0.0;
    var leftEnergy = 0.0;
    var rightEnergy = 0.0;
    for (var left = 0; left < signal.length - 1; left++) {
      final target = times[left].add(Duration(
        microseconds: (periodSeconds * Duration.microsecondsPerSecond).round(),
      ));
      while (right + 1 < times.length && times[right + 1].isBefore(target)) {
        right++;
      }
      final next = min(right + 1, times.length - 1);
      final candidate = target.difference(times[right]).abs() <=
              times[next].difference(target).abs()
          ? right
          : next;
      if (times[candidate].difference(target).abs() >
          const Duration(milliseconds: 80)) {
        continue;
      }
      final a = signal[left] - mean;
      final b = signal[candidate] - mean;
      dot += a * b;
      leftEnergy += a * a;
      rightEnergy += b * b;
    }
    if (leftEnergy <= 1e-9 || rightEnergy <= 1e-9) return 0;
    return dot / sqrt(leftEnergy * rightEnergy);
  }

  double _median(List<double> values) {
    if (values.isEmpty) return double.nan;
    final sorted = List<double>.from(values)..sort();
    final middle = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[middle]
        : (sorted[middle - 1] + sorted[middle]) / 2;
  }
}

class _Candidate {
  final double spm;
  final double confidence;
  final int strokeCount;
  final double coefficientOfVariation;
  final bool positive;
  final List<int> extremaIndices;

  const _Candidate({
    required this.spm,
    required this.confidence,
    required this.strokeCount,
    required this.coefficientOfVariation,
    required this.positive,
    required this.extremaIndices,
  });

  double get score => confidence - coefficientOfVariation * 0.1;
}

class _Vector {
  final double x;
  final double y;
  final double z;

  const _Vector(this.x, this.y, this.z);

  _Vector operator +(_Vector other) =>
      _Vector(x + other.x, y + other.y, z + other.z);
  _Vector operator -(_Vector other) =>
      _Vector(x - other.x, y - other.y, z - other.z);
  _Vector operator *(double scalar) =>
      _Vector(x * scalar, y * scalar, z * scalar);
  double get length => sqrt(x * x + y * y + z * z);
}
