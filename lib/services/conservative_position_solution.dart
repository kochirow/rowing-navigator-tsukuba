import 'dart:math' as math;

/// 生GNSS優先の軽量alpha-beta解。Stage 1ではshadow記録専用であり、
/// 表示・警告・共有には絶対に使わない。Stage 2で選択解候補として評価する。
class ConservativePositionSolution {
  double? _latitude;
  double? _longitude;
  double _velocityLatitudePerSecond = 0;
  double _velocityLongitudePerSecond = 0;
  Duration? _elapsed;

  ConservativePositionEstimate update({
    required double latitude,
    required double longitude,
    required Duration elapsed,
    double? speedMetersPerSecond,
    double? headingDegrees,
  }) {
    final previousElapsed = _elapsed;
    if (_latitude == null || _longitude == null || previousElapsed == null) {
      _latitude = latitude;
      _longitude = longitude;
      _elapsed = elapsed;
      return ConservativePositionEstimate(
          latitude: latitude, longitude: longitude);
    }
    final seconds = math.max(
        0.001,
        (elapsed - previousElapsed).inMicroseconds /
            Duration.microsecondsPerSecond);
    final predictedLatitude = _latitude! + _velocityLatitudePerSecond * seconds;
    final predictedLongitude =
        _longitude! + _velocityLongitudePerSecond * seconds;
    const alpha = .85;
    const beta = .15;
    final residualLatitude = latitude - predictedLatitude;
    final residualLongitude = longitude - predictedLongitude;
    _latitude = predictedLatitude + alpha * residualLatitude;
    _longitude = predictedLongitude + alpha * residualLongitude;
    _velocityLatitudePerSecond += beta * residualLatitude / seconds;
    _velocityLongitudePerSecond += beta * residualLongitude / seconds;
    _elapsed = elapsed;
    return ConservativePositionEstimate(
        latitude: _latitude!, longitude: _longitude!);
  }

  void reset() {
    _latitude = null;
    _longitude = null;
    _velocityLatitudePerSecond = 0;
    _velocityLongitudePerSecond = 0;
    _elapsed = null;
  }
}

class ConservativePositionEstimate {
  final double latitude;
  final double longitude;
  const ConservativePositionEstimate(
      {required this.latitude, required this.longitude});
}
