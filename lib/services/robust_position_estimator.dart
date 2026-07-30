import 'dart:math' as math;

/// 推定器が最新の測位をどのように扱ったかを示す。
enum PositionEstimateDisposition {
  initialized,
  accepted,
  downWeighted,
  rejected,
  reacquired,
}

/// GNSS測位を更新した後の軽量な位置推定結果。
///
/// [covarianceUncertaintyMeters] はフィルタ内部の共分散から求めた
/// 95% 相当の半径。[uncertaintyMeters] はそこへ「報告accuracyに対する
/// 下限比率」と「絶対下限」を課した、安全判定で使う値。フィルタが収束すれば
/// 報告accuracyを下回り得るが、系統誤差ぶんは必ず残す。
class RobustPositionEstimate {
  final double latitude;
  final double longitude;
  final double speedMetersPerSecond;
  final double headingDegrees;
  final double reportedAccuracyMeters;
  final double covarianceUncertaintyMeters;
  final double uncertaintyMeters;
  final double innovationMeters;
  final PositionEstimateDisposition disposition;

  const RobustPositionEstimate({
    required this.latitude,
    required this.longitude,
    required this.speedMetersPerSecond,
    required this.headingDegrees,
    required this.reportedAccuracyMeters,
    required this.covarianceUncertaintyMeters,
    required this.uncertaintyMeters,
    required this.innovationMeters,
    required this.disposition,
  });
}

/// GNSSの更新時だけ動作する4状態のロバストKalman推定器。
///
/// 状態は局所平面上の east, north, east速度, north速度。
/// Timer、センサー購読、外部行列ライブラリは使わず、固定サイズのスカラー演算だけを
/// [update] 呼び出しご1回実行する。
///
/// プロセスノイズはローイング艇の運動特性に合わせて非等方にする。艇は
/// スケグとリグで横滑りをほとんど起こさない一方、1ストローク内の前後加減速は
/// 大きい。等方ノイズだと横方向の共分散が過大に育ち、GNSSの横ずれをそのまま
/// 受け入れて推定航跡が蛇行し、方位推定まで揺れる。
class RobustPositionEstimator {
  static const double _earthRadiusMeters = 6371008.8;
  static const double _degreesToRadians = math.pi / 180;
  static const double _radiansToDegrees = 180 / math.pi;
  static const double _confidence95Multiplier = 2.44774683068;

  /// GNSSのaccuracyが過小な場合にも使う観測ノイズの下限。
  final double minimumAccuracyMeters;

  /// 進行方向(surge)のプロセスノイズ。ストローク内の加減速を吸収する。
  /// SPMが得られる場合は [strokeSpeedAmplitudeMetersPerSecond] から動的に決める。
  final double surgeAccelerationNoiseMetersPerSecondSquared;

  /// 横方向(sway)のプロセスノイズ。艇は横滑りしないため小さく保つ。
  final double swayAccelerationNoiseMetersPerSecondSquared;

  /// 停止・回頭中など進行方向が定まらないときに使う等方プロセスノイズ。
  final double maneuveringAccelerationNoiseMetersPerSecondSquared;

  /// この速度以上のときだけ、進行方向基準の非等方ノイズを使う。
  final double directionalNoiseMinimumSpeedMetersPerSecond;

  /// 1ストローク内の艇速振幅 [m/s]。SPM連動のノイズ推定に使う。
  final double strokeSpeedAmplitudeMetersPerSecond;

  /// この正規化innovationを超えた測位は重みを下げる。
  final double softGateNormalizedSquared;

  /// この正規化innovationを超えた単発測位は棄却する。
  final double hardGateNormalizedSquared;

  /// 予測を継続せず、最新GNSSで再捕捉する最大間隔。
  final Duration maximumPredictionGap;

  /// 再捕捉時に直前の速度を引き継ぐ際の減衰時定数 [秒]。
  /// 艇は数秒では止まらないため、速度を0へ落とすと停止距離が0となり
  /// 警告レベルを不当に下げてしまう。
  final double velocityDecayTimeConstantSeconds;

  /// 棄却候補がこの回数連続して妥当な軌跡を作ったら再捕捉する。
  final int reacquisitionSampleCount;

  /// 再捕捉候補間で許容する最大速度。
  final double maximumReacquisitionSpeedMetersPerSecond;

  final Duration maximumReacquisitionSampleGap;

  /// フィルタ後の不確実性が端末報告accuracyを下回れる下限比率。
  /// 1.0で従来どおり「報告値を決して下回らない」。
  final double minimumUncertaintyFractionOfReported;

  /// マルチパス等の系統誤差は平均化で消えないため設ける絶対下限 [m]。
  final double uncertaintyFloorMeters;

  RobustPositionEstimator({
    this.minimumAccuracyMeters = 4,
    this.surgeAccelerationNoiseMetersPerSecondSquared = 1.5,
    this.swayAccelerationNoiseMetersPerSecondSquared = 0.3,
    this.maneuveringAccelerationNoiseMetersPerSecondSquared = 1.2,
    this.directionalNoiseMinimumSpeedMetersPerSecond = 0.6,
    this.strokeSpeedAmplitudeMetersPerSecond = 0.45,
    this.softGateNormalizedSquared = 6,
    this.hardGateNormalizedSquared = 25,
    this.maximumPredictionGap = const Duration(seconds: 5),
    this.velocityDecayTimeConstantSeconds = 8,
    this.reacquisitionSampleCount = 3,
    this.maximumReacquisitionSpeedMetersPerSecond = 12,
    this.maximumReacquisitionSampleGap = const Duration(seconds: 3),
    this.minimumUncertaintyFractionOfReported = 0.5,
    this.uncertaintyFloorMeters = 3,
  })  : assert(minimumAccuracyMeters > 0),
        assert(surgeAccelerationNoiseMetersPerSecondSquared > 0),
        assert(swayAccelerationNoiseMetersPerSecondSquared > 0),
        assert(maneuveringAccelerationNoiseMetersPerSecondSquared > 0),
        assert(directionalNoiseMinimumSpeedMetersPerSecond >= 0),
        assert(strokeSpeedAmplitudeMetersPerSecond > 0),
        assert(softGateNormalizedSquared > 0),
        assert(hardGateNormalizedSquared > softGateNormalizedSquared),
        assert(maximumPredictionGap > Duration.zero),
        assert(velocityDecayTimeConstantSeconds > 0),
        assert(reacquisitionSampleCount >= 2),
        assert(maximumReacquisitionSpeedMetersPerSecond > 0),
        assert(maximumReacquisitionSampleGap > Duration.zero),
        assert(minimumUncertaintyFractionOfReported > 0 &&
            minimumUncertaintyFractionOfReported <= 1),
        assert(uncertaintyFloorMeters >= 0);

  bool get isInitialized => _lastElapsed != null;

  double? _originLatitude;
  double? _originLongitude;
  double _originCosLatitude = 1;
  Duration? _lastElapsed;

  double _east = 0;
  double _north = 0;
  double _velocityEast = 0;
  double _velocityNorth = 0;

  // 4x4共分散のうち、east/north間を独立とした2つの2x2対称ブロック。
  double _eastPositionVariance = 0;
  double _eastPositionVelocityCovariance = 0;
  double _eastVelocityVariance = 0;
  double _northPositionVariance = 0;
  double _northPositionVelocityCovariance = 0;
  double _northVelocityVariance = 0;

  double? _pendingEast;
  double? _pendingNorth;
  Duration? _pendingElapsed;
  int _pendingCount = 0;

  /// すべての状態を破棄し、次の有効測位を新しい原点とする。
  void reset() {
    _originLatitude = null;
    _originLongitude = null;
    _originCosLatitude = 1;
    _lastElapsed = null;
    _east = 0;
    _north = 0;
    _velocityEast = 0;
    _velocityNorth = 0;
    _eastPositionVariance = 0;
    _eastPositionVelocityCovariance = 0;
    _eastVelocityVariance = 0;
    _northPositionVariance = 0;
    _northPositionVelocityCovariance = 0;
    _northVelocityVariance = 0;
    _clearPendingReacquisition();
  }

  /// GNSS測位で1回更新する。
  ///
  /// [elapsed] は航行開始後などの単調増加時刻を渡す。GNSSの測位時刻を
  /// 基準にした値を渡すと、処理遅延のジッタによる dt 誤差を避けられる。
  /// 時刻が同じ、または逆行した測位と、無効な必須値は `null` を返して
  /// 状態を変更しない。
  ///
  /// [strokeRateSpm] が渡された場合、1ストローク内の艇速振動を未モデル化
  /// 外乱として surge 側のプロセスノイズへ反映する。
  RobustPositionEstimate? update({
    required double latitude,
    required double longitude,
    required double accuracyMeters,
    required Duration elapsed,
    double? speedMetersPerSecond,
    double? headingDegrees,
    double? speedAccuracyMetersPerSecond,
    double? headingAccuracyDegrees,
    double? strokeRateSpm,
  }) {
    if (!_isValidRequiredMeasurement(
      latitude,
      longitude,
      accuracyMeters,
      elapsed,
    )) {
      return null;
    }

    final lastElapsed = _lastElapsed;
    if (lastElapsed != null && elapsed <= lastElapsed) return null;

    final velocityObservation = _velocityObservation(
      speedMetersPerSecond: speedMetersPerSecond,
      headingDegrees: headingDegrees,
      speedAccuracyMetersPerSecond: speedAccuracyMetersPerSecond,
      headingAccuracyDegrees: headingAccuracyDegrees,
    );
    final measurementSigma = math.max(accuracyMeters, minimumAccuracyMeters);

    if (lastElapsed == null) {
      _originLatitude = latitude;
      _originLongitude = longitude;
      _originCosLatitude = math.cos(latitude * _degreesToRadians);
      _lastElapsed = elapsed;
      _initializeState(
        east: 0,
        north: 0,
        measurementSigma: measurementSigma,
        velocityObservation: velocityObservation,
      );
      return _result(
        reportedAccuracyMeters: accuracyMeters,
        innovationMeters: 0,
        disposition: PositionEstimateDisposition.initialized,
      );
    }

    final delta = elapsed - lastElapsed;
    _lastElapsed = elapsed;
    final measurement = _toLocal(latitude, longitude);
    final deltaSeconds = delta.inMicroseconds / Duration.microsecondsPerSecond;

    if (delta > maximumPredictionGap) {
      // GNSS速度観測が無い場合も、直前の速度を惰行として減衰させて
      // 引き継ぐ。0へ落とすと停止距離が0になり、橋の下を抜けた直後などに
      // 警告レベルが不当に下がる。
      _initializeState(
        east: measurement.$1,
        north: measurement.$2,
        measurementSigma: measurementSigma,
        velocityObservation:
            velocityObservation ?? _decayedCarriedVelocity(deltaSeconds),
      );
      return _result(
        reportedAccuracyMeters: accuracyMeters,
        innovationMeters: 0,
        disposition: PositionEstimateDisposition.reacquired,
      );
    }

    _predict(deltaSeconds, strokeRateSpm: strokeRateSpm);

    final innovationEast = measurement.$1 - _east;
    final innovationNorth = measurement.$2 - _north;
    final innovationMeters = math.sqrt(
      innovationEast * innovationEast + innovationNorth * innovationNorth,
    );
    final measurementVariance = measurementSigma * measurementSigma;
    final normalizedInnovationSquared = innovationEast *
            innovationEast /
            (_eastPositionVariance + measurementVariance) +
        innovationNorth *
            innovationNorth /
            (_northPositionVariance + measurementVariance);

    // 以前の棄却候補に続く一貫した軌跡は、共分散の増加で
    // hard gate内へ戻っても再捕捉回数に含める。これにより旋回や
    // GNSS復帰時に推定位置が古い軌跡でフリーズするのを防ぐ。
    final derivedPendingVelocity = _derivedPendingVelocity(
      currentEast: measurement.$1,
      currentNorth: measurement.$2,
      currentElapsed: elapsed,
    );
    var recordedAsPending = false;
    if (_pendingCount > 0) {
      recordedAsPending = true;
      final shouldReacquire = _recordReacquisitionCandidate(
        east: measurement.$1,
        north: measurement.$2,
        elapsed: elapsed,
      );
      if (shouldReacquire) {
        _initializeState(
          east: measurement.$1,
          north: measurement.$2,
          measurementSigma: measurementSigma,
          velocityObservation: velocityObservation ?? derivedPendingVelocity,
        );
        return _result(
          reportedAccuracyMeters: accuracyMeters,
          innovationMeters: innovationMeters,
          disposition: PositionEstimateDisposition.reacquired,
        );
      }
    }

    if (normalizedInnovationSquared > hardGateNormalizedSquared) {
      if (!recordedAsPending) {
        _recordReacquisitionCandidate(
          east: measurement.$1,
          north: measurement.$2,
          elapsed: elapsed,
        );
      }
      return _result(
        reportedAccuracyMeters: accuracyMeters,
        innovationMeters: innovationMeters,
        disposition: PositionEstimateDisposition.rejected,
      );
    }

    _clearPendingReacquisition();
    var robustMeasurementVariance = measurementVariance;
    var disposition = PositionEstimateDisposition.accepted;
    if (normalizedInnovationSquared > softGateNormalizedSquared) {
      robustMeasurementVariance *=
          normalizedInnovationSquared / softGateNormalizedSquared;
      disposition = PositionEstimateDisposition.downWeighted;
    }

    _updateEastPosition(measurement.$1, robustMeasurementVariance);
    _updateNorthPosition(measurement.$2, robustMeasurementVariance);
    if (velocityObservation != null) {
      _updateEastVelocity(
        velocityObservation.east,
        velocityObservation.variance,
      );
      _updateNorthVelocity(
        velocityObservation.north,
        velocityObservation.variance,
      );
    }

    return _result(
      reportedAccuracyMeters: accuracyMeters,
      innovationMeters: innovationMeters,
      disposition: disposition,
    );
  }

  bool _isValidRequiredMeasurement(
    double latitude,
    double longitude,
    double accuracyMeters,
    Duration elapsed,
  ) =>
      latitude.isFinite &&
      longitude.isFinite &&
      accuracyMeters.isFinite &&
      latitude.abs() <= 90 &&
      longitude.abs() <= 180 &&
      accuracyMeters > 0 &&
      elapsed >= Duration.zero;

  void _initializeState({
    required double east,
    required double north,
    required double measurementSigma,
    required _VelocityObservation? velocityObservation,
  }) {
    _east = east;
    _north = north;
    _velocityEast = velocityObservation?.east ?? 0;
    _velocityNorth = velocityObservation?.north ?? 0;
    final positionVariance = measurementSigma * measurementSigma;
    final velocityVariance = velocityObservation?.variance ?? 9;
    _eastPositionVariance = positionVariance;
    _eastPositionVelocityCovariance = 0;
    _eastVelocityVariance = velocityVariance;
    _northPositionVariance = positionVariance;
    _northPositionVelocityCovariance = 0;
    _northVelocityVariance = velocityVariance;
    _clearPendingReacquisition();
  }

  /// 現在の推定速度から惰行速度を作る。再捕捉時のみ使う。
  _VelocityObservation? _decayedCarriedVelocity(double gapSeconds) {
    final speed = math.sqrt(
      _velocityEast * _velocityEast + _velocityNorth * _velocityNorth,
    );
    if (speed <= 1e-3 || !speed.isFinite) return null;
    final decay = math.exp(-gapSeconds / velocityDecayTimeConstantSeconds);
    // 観測ではなく推測なので、途絶が長いほど分散を広げる。
    final variance = math.min(9.0, 1.0 + gapSeconds);
    return _VelocityObservation(
      east: _velocityEast * decay,
      north: _velocityNorth * decay,
      variance: variance,
    );
  }

  /// SPMから、1ストローク内の艇速振動が生む実効的な加速度ノイズを求める。
  ///
  /// 艇速は概ね1ストローク周期の正弦波で振動する。角周波数 2π·(spm/60) と
  /// 振幅 [strokeSpeedAmplitudeMetersPerSecond] の積が加速度の代表値になる。
  /// 1Hz観測ではこの振動を分解できないため、そのまま未モデル化外乱として扱う。
  double _surgeAccelerationNoise(double? strokeRateSpm) {
    final base = surgeAccelerationNoiseMetersPerSecondSquared;
    if (strokeRateSpm == null ||
        !strokeRateSpm.isFinite ||
        strokeRateSpm <= 0) {
      return base;
    }
    final strokeHz = (strokeRateSpm / 60).clamp(0.0, 1.2);
    final modelled =
        2 * math.pi * strokeHz * strokeSpeedAmplitudeMetersPerSecond;
    // モデルが外れても発散・過信しないよう基準値の0.6〜2.0倍に収める。
    return modelled.clamp(base * 0.6, base * 2.0).toDouble();
  }

  void _predict(double deltaSeconds, {double? strokeRateSpm}) {
    _east += _velocityEast * deltaSeconds;
    _north += _velocityNorth * deltaSeconds;

    final speed = math.sqrt(
      _velocityEast * _velocityEast + _velocityNorth * _velocityNorth,
    );
    final double surgeVariance;
    final double swayVariance;
    // heading θ は北基準・時計回り。進行方向の単位ベクトルは (sinθ, cosθ)、
    // 横方向は (cosθ, -sinθ)。
    final double sinHeading;
    final double cosHeading;
    if (speed >= directionalNoiseMinimumSpeedMetersPerSecond) {
      final surge = _surgeAccelerationNoise(strokeRateSpm);
      surgeVariance = surge * surge;
      swayVariance = swayAccelerationNoiseMetersPerSecondSquared *
          swayAccelerationNoiseMetersPerSecondSquared;
      sinHeading = _velocityEast / speed;
      cosHeading = _velocityNorth / speed;
    } else {
      // 停止・回頭中は進行方向が定まらないため等方へ戻す。
      final isotropic = maneuveringAccelerationNoiseMetersPerSecondSquared;
      surgeVariance = isotropic * isotropic;
      swayVariance = surgeVariance;
      sinHeading = 0;
      cosHeading = 1;
    }
    // surge/sway の分散を east/north 軸へ射影する。east-north間の相関項は
    // 既存の2ブロック構造に合わせて落とす(対角近似)。等方の場合は厳密。
    final accelerationVarianceEast = surgeVariance * sinHeading * sinHeading +
        swayVariance * cosHeading * cosHeading;
    final accelerationVarianceNorth = surgeVariance * cosHeading * cosHeading +
        swayVariance * sinHeading * sinHeading;

    final deltaSquared = deltaSeconds * deltaSeconds;
    final deltaCubed = deltaSquared * deltaSeconds;
    final deltaFourth = deltaSquared * deltaSquared;

    final oldEastCovariance = _eastPositionVelocityCovariance;
    final oldEastVelocityVariance = _eastVelocityVariance;
    _eastPositionVariance += 2 * deltaSeconds * oldEastCovariance +
        deltaSquared * oldEastVelocityVariance +
        0.25 * deltaFourth * accelerationVarianceEast;
    _eastPositionVelocityCovariance += deltaSeconds * oldEastVelocityVariance +
        0.5 * deltaCubed * accelerationVarianceEast;
    _eastVelocityVariance += deltaSquared * accelerationVarianceEast;

    final oldNorthCovariance = _northPositionVelocityCovariance;
    final oldNorthVelocityVariance = _northVelocityVariance;
    _northPositionVariance += 2 * deltaSeconds * oldNorthCovariance +
        deltaSquared * oldNorthVelocityVariance +
        0.25 * deltaFourth * accelerationVarianceNorth;
    _northPositionVelocityCovariance +=
        deltaSeconds * oldNorthVelocityVariance +
            0.5 * deltaCubed * accelerationVarianceNorth;
    _northVelocityVariance += deltaSquared * accelerationVarianceNorth;
  }

  void _updateEastPosition(double measurement, double variance) {
    final innovation = measurement - _east;
    final innovationVariance = _eastPositionVariance + variance;
    final positionGain = _eastPositionVariance / innovationVariance;
    final velocityGain = _eastPositionVelocityCovariance / innovationVariance;
    final oldPositionVariance = _eastPositionVariance;
    final oldCovariance = _eastPositionVelocityCovariance;
    _east += positionGain * innovation;
    _velocityEast += velocityGain * innovation;
    _eastPositionVariance =
        oldPositionVariance - positionGain * oldPositionVariance;
    _eastPositionVelocityCovariance =
        oldCovariance - positionGain * oldCovariance;
    _eastVelocityVariance -= velocityGain * oldCovariance;
  }

  void _updateNorthPosition(double measurement, double variance) {
    final innovation = measurement - _north;
    final innovationVariance = _northPositionVariance + variance;
    final positionGain = _northPositionVariance / innovationVariance;
    final velocityGain = _northPositionVelocityCovariance / innovationVariance;
    final oldPositionVariance = _northPositionVariance;
    final oldCovariance = _northPositionVelocityCovariance;
    _north += positionGain * innovation;
    _velocityNorth += velocityGain * innovation;
    _northPositionVariance =
        oldPositionVariance - positionGain * oldPositionVariance;
    _northPositionVelocityCovariance =
        oldCovariance - positionGain * oldCovariance;
    _northVelocityVariance -= velocityGain * oldCovariance;
  }

  void _updateEastVelocity(double measurement, double variance) {
    final innovation = measurement - _velocityEast;
    final innovationVariance = _eastVelocityVariance + variance;
    final positionGain = _eastPositionVelocityCovariance / innovationVariance;
    final velocityGain = _eastVelocityVariance / innovationVariance;
    final oldVelocityVariance = _eastVelocityVariance;
    final oldCovariance = _eastPositionVelocityCovariance;
    _east += positionGain * innovation;
    _velocityEast += velocityGain * innovation;
    _eastPositionVariance -= positionGain * oldCovariance;
    _eastPositionVelocityCovariance =
        oldCovariance - velocityGain * oldCovariance;
    _eastVelocityVariance =
        oldVelocityVariance - velocityGain * oldVelocityVariance;
  }

  void _updateNorthVelocity(double measurement, double variance) {
    final innovation = measurement - _velocityNorth;
    final innovationVariance = _northVelocityVariance + variance;
    final positionGain = _northPositionVelocityCovariance / innovationVariance;
    final velocityGain = _northVelocityVariance / innovationVariance;
    final oldVelocityVariance = _northVelocityVariance;
    final oldCovariance = _northPositionVelocityCovariance;
    _north += positionGain * innovation;
    _velocityNorth += velocityGain * innovation;
    _northPositionVariance -= positionGain * oldCovariance;
    _northPositionVelocityCovariance =
        oldCovariance - velocityGain * oldCovariance;
    _northVelocityVariance =
        oldVelocityVariance - velocityGain * oldVelocityVariance;
  }

  _VelocityObservation? _velocityObservation({
    required double? speedMetersPerSecond,
    required double? headingDegrees,
    required double? speedAccuracyMetersPerSecond,
    required double? headingAccuracyDegrees,
  }) {
    if (speedMetersPerSecond == null ||
        headingDegrees == null ||
        !speedMetersPerSecond.isFinite ||
        !headingDegrees.isFinite ||
        speedMetersPerSecond < 0 ||
        speedMetersPerSecond > maximumReacquisitionSpeedMetersPerSecond) {
      return null;
    }
    final normalizedHeading = _normalizeHeading(headingDegrees);
    final headingRadians = normalizedHeading * _degreesToRadians;
    final speedSigma = speedAccuracyMetersPerSecond != null &&
            speedAccuracyMetersPerSecond.isFinite &&
            speedAccuracyMetersPerSecond > 0
        ? speedAccuracyMetersPerSecond
        : 1.5;
    final headingSigmaDegrees = headingAccuracyDegrees != null &&
            headingAccuracyDegrees.isFinite &&
            headingAccuracyDegrees > 0 &&
            headingAccuracyDegrees <= 180
        ? headingAccuracyDegrees
        : 45;
    // 方位誤差が速度ベクトルの各軸に与える最大影響を両軸に与える。
    final headingVelocitySigma = speedMetersPerSecond *
        math.sin(math.min(90, headingSigmaDegrees) * _degreesToRadians).abs();
    final componentSigma = math.max(
      0.5,
      math.sqrt(speedSigma * speedSigma +
          headingVelocitySigma * headingVelocitySigma),
    );
    return _VelocityObservation(
      east: speedMetersPerSecond * math.sin(headingRadians),
      north: speedMetersPerSecond * math.cos(headingRadians),
      variance: componentSigma * componentSigma,
    );
  }

  bool _recordReacquisitionCandidate({
    required double east,
    required double north,
    required Duration elapsed,
  }) {
    final previousEast = _pendingEast;
    final previousNorth = _pendingNorth;
    final previousElapsed = _pendingElapsed;
    var isConsistent = false;
    if (previousEast != null &&
        previousNorth != null &&
        previousElapsed != null) {
      final delta = elapsed - previousElapsed;
      if (delta > Duration.zero && delta <= maximumReacquisitionSampleGap) {
        final seconds = delta.inMicroseconds / Duration.microsecondsPerSecond;
        final candidateDistance = math.sqrt(
          (east - previousEast) * (east - previousEast) +
              (north - previousNorth) * (north - previousNorth),
        );
        isConsistent = candidateDistance / seconds <=
            maximumReacquisitionSpeedMetersPerSecond;
      }
    }
    _pendingCount = isConsistent ? _pendingCount + 1 : 1;
    _pendingEast = east;
    _pendingNorth = north;
    _pendingElapsed = elapsed;
    return _pendingCount >= reacquisitionSampleCount;
  }

  _VelocityObservation? _derivedPendingVelocity({
    required double currentEast,
    required double currentNorth,
    required Duration currentElapsed,
  }) {
    final previousEast = _pendingEast;
    final previousNorth = _pendingNorth;
    final previousElapsed = _pendingElapsed;
    if (previousEast == null ||
        previousNorth == null ||
        previousElapsed == null) {
      return null;
    }
    final seconds = (currentElapsed - previousElapsed).inMicroseconds /
        Duration.microsecondsPerSecond;
    if (seconds <= 0) return null;
    final eastVelocity = (currentEast - previousEast) / seconds;
    final northVelocity = (currentNorth - previousNorth) / seconds;
    final speed = math.sqrt(
      eastVelocity * eastVelocity + northVelocity * northVelocity,
    );
    if (speed > maximumReacquisitionSpeedMetersPerSecond) return null;
    return _VelocityObservation(
      east: eastVelocity,
      north: northVelocity,
      variance: 4,
    );
  }

  void _clearPendingReacquisition() {
    _pendingEast = null;
    _pendingNorth = null;
    _pendingElapsed = null;
    _pendingCount = 0;
  }

  (double, double) _toLocal(double latitude, double longitude) {
    final latitudeDelta = latitude - _originLatitude!;
    var longitudeDelta = longitude - _originLongitude!;
    if (longitudeDelta > 180) longitudeDelta -= 360;
    if (longitudeDelta < -180) longitudeDelta += 360;
    return (
      longitudeDelta *
          _degreesToRadians *
          _earthRadiusMeters *
          _originCosLatitude,
      latitudeDelta * _degreesToRadians * _earthRadiusMeters,
    );
  }

  (double, double) _toGeodetic(double east, double north) {
    final latitude =
        _originLatitude! + north / _earthRadiusMeters * _radiansToDegrees;
    final longitude = _normalizeLongitude(_originLongitude! +
        east / (_earthRadiusMeters * _originCosLatitude) * _radiansToDegrees);
    return (latitude, longitude);
  }

  RobustPositionEstimate _result({
    required double reportedAccuracyMeters,
    required double innovationMeters,
    required PositionEstimateDisposition disposition,
  }) {
    final geodetic = _toGeodetic(_east, _north);
    final speed = math.sqrt(
      _velocityEast * _velocityEast + _velocityNorth * _velocityNorth,
    );
    final covarianceUncertainty = _confidence95Multiplier *
        math.sqrt(math.max(
          _eastPositionVariance,
          _northPositionVariance,
        ));
    // フィルタが収束したぶんは安全マージンへ反映する。ただしマルチパスなどの
    // 系統誤差は平均化で消えないため、絶対下限と報告値に対する下限比率を残す。
    final optimismFloor = math.max(
      uncertaintyFloorMeters,
      reportedAccuracyMeters * minimumUncertaintyFractionOfReported,
    );
    return RobustPositionEstimate(
      latitude: geodetic.$1,
      longitude: geodetic.$2,
      speedMetersPerSecond: speed,
      headingDegrees: speed > 1e-6
          ? _normalizeHeading(
              math.atan2(_velocityEast, _velocityNorth) * _radiansToDegrees,
            )
          : 0,
      reportedAccuracyMeters: reportedAccuracyMeters,
      covarianceUncertaintyMeters: covarianceUncertainty,
      uncertaintyMeters: math.max(optimismFloor, covarianceUncertainty),
      innovationMeters: innovationMeters,
      disposition: disposition,
    );
  }

  double _normalizeHeading(double value) {
    final normalized = value % 360;
    return normalized < 0 ? normalized + 360 : normalized;
  }

  double _normalizeLongitude(double value) {
    var normalized = (value + 180) % 360;
    if (normalized < 0) normalized += 360;
    return normalized - 180;
  }
}

class _VelocityObservation {
  final double east;
  final double north;
  final double variance;

  const _VelocityObservation({
    required this.east,
    required this.north,
    required this.variance,
  });
}
