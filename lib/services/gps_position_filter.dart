import 'package:geolocator/geolocator.dart';

/// 航行判定に使うGPS測位を選別する軽量フィルタ。
/// 棄却した測位は送信・衝突判定・走行距離に一切使わない。
class GpsPositionFilter {
  final double maxAccuracyMeters;
  final double maxSpeedMetersPerSecond;
  final Duration maxTimestampAge;
  final bool rejectMocked;
  final bool acceptLowAccuracy;
  Position? _lastAccepted;
  Duration? _lastAcceptedElapsed;

  GpsPositionFilter({
    required this.maxAccuracyMeters,
    required this.maxSpeedMetersPerSecond,
    this.maxTimestampAge = const Duration(seconds: 10),
    this.rejectMocked = false,
    this.acceptLowAccuracy = false,
  });

  void reset() {
    _lastAccepted = null;
    _lastAcceptedElapsed = null;
  }

  /// 航行用Stopwatchのreset後に、直前の正常fixを同じ単調時刻へ載せ替える。
  void rebaseLastAcceptedElapsed(Duration elapsed) {
    if (_lastAccepted != null) _lastAcceptedElapsed = elapsed;
  }

  /// 航行開始の足掛かりとして使える座標かだけを確認する。
  ///
  /// accuracyや測位時刻は航行中の品質監視で扱う。開始時にそれらまで
  /// 必須にすると、一時的に精度が悪いだけでGPS stream自体を開始できない。
  bool hasValidCoordinates(Position position) {
    return position.latitude.isFinite &&
        position.longitude.isFinite &&
        position.latitude.abs() <= 90 &&
        position.longitude.abs() <= 180;
  }

  bool isLowAccuracy(Position position) =>
      position.accuracy.isFinite && position.accuracy > maxAccuracyMeters;

  bool accepts(
    Position position, {
    DateTime? receivedAt,
    Duration? receivedElapsed,
  }) {
    final now = receivedAt ?? DateTime.now();
    if ((rejectMocked && position.isMocked) ||
        !hasValidCoordinates(position) ||
        !position.accuracy.isFinite ||
        position.accuracy <= 0 ||
        (isLowAccuracy(position) && !acceptLowAccuracy)) {
      return false;
    }
    if (now.difference(position.timestamp).abs() > maxTimestampAge) {
      return false;
    }

    final previous = _lastAccepted;
    if (previous != null) {
      final previousElapsed = _lastAcceptedElapsed;
      final elapsedSeconds = receivedElapsed != null && previousElapsed != null
          ? (receivedElapsed - previousElapsed).inMicroseconds / 1000000
          : position.timestamp.difference(previous.timestamp).inMicroseconds /
              1000000;
      if (elapsedSeconds <= 0) return false;
      final distance = Geolocator.distanceBetween(
        previous.latitude,
        previous.longitude,
        position.latitude,
        position.longitude,
      );
      // 低精度fixの見かけ上の位置飛びはロバストKalman側でinnovationを
      // 重み下げ・棄却する。ここで先に落とすと予測更新自体が止まる。
      if (distance / elapsedSeconds > maxSpeedMetersPerSecond &&
          !(acceptLowAccuracy && isLowAccuracy(position))) {
        return false;
      }
    }

    _lastAccepted = position;
    _lastAcceptedElapsed = receivedElapsed;
    return true;
  }
}
