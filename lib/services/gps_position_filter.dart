import 'package:geolocator/geolocator.dart';

/// 航行用フィルタが測位をどの理由で採用・棄却したか。
enum GpsPositionFilterReason {
  accepted,
  mocked,
  invalidCoordinate,
  invalidAccuracy,
  lowAccuracy,
  staleTimestamp,
  nonMonotonic,
  implausibleSpeed,
  lowAccuracyMeasurementBypassed,
  lowAccuracyAnchorBypassed,
}

/// GPS測位の採否と、その判断に使った直前測位との差分。
class GpsPositionFilterResult {
  final bool accepted;
  final GpsPositionFilterReason reason;

  /// 良好な古い基準点から離れた場所で、一貫した測位が続いたため
  /// 速度ゲートの基準点を最新位置へ付け替えたか。
  final bool speedAnchorReacquired;
  final double? previousAccuracyMeters;
  final double? distanceMeters;
  final double? elapsedSeconds;

  const GpsPositionFilterResult({
    required this.accepted,
    required this.reason,
    this.speedAnchorReacquired = false,
    this.previousAccuracyMeters,
    this.distanceMeters,
    this.elapsedSeconds,
  });
}

/// 航行判定に使うGPS測位を選別する軽量フィルタ。
/// 棄却した測位は送信・衝突判定・走行距離に一切使わない。
class GpsPositionFilter {
  final double maxAccuracyMeters;
  final double maxSpeedMetersPerSecond;
  final Duration maxTimestampAge;
  final bool rejectMocked;
  final bool acceptLowAccuracy;
  final int reacquisitionSampleCount;
  final Duration maximumReacquisitionSampleGap;
  Position? _lastAccepted;
  Duration? _lastAcceptedElapsed;
  Position? _pendingReacquisition;
  Duration? _pendingReacquisitionElapsed;
  int _pendingReacquisitionCount = 0;

  GpsPositionFilter({
    required this.maxAccuracyMeters,
    required this.maxSpeedMetersPerSecond,
    this.maxTimestampAge = const Duration(seconds: 10),
    this.rejectMocked = false,
    this.acceptLowAccuracy = false,
    this.reacquisitionSampleCount = 3,
    this.maximumReacquisitionSampleGap = const Duration(seconds: 3),
  })  : assert(reacquisitionSampleCount >= 2),
        assert(maximumReacquisitionSampleGap > Duration.zero);

  void reset() {
    _lastAccepted = null;
    _lastAcceptedElapsed = null;
    _clearPendingReacquisition();
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
  }) =>
      evaluate(
        position,
        receivedAt: receivedAt,
        receivedElapsed: receivedElapsed,
      ).accepted;

  /// 測位を選別し、後日の実機診断に使える理由を返す。
  ///
  /// 直前の受理測位が低精度な場合は、その座標を速度計算の
  /// 信頼できる基準点として扱わない。単純にaccuracy半径ぶんの
  /// ジャンプを許すのではなく、既存のロバスト推定器へ渡す。
  GpsPositionFilterResult evaluate(
    Position position, {
    DateTime? receivedAt,
    Duration? receivedElapsed,
  }) {
    final now = receivedAt ?? DateTime.now();
    if (rejectMocked && position.isMocked) {
      return const GpsPositionFilterResult(
        accepted: false,
        reason: GpsPositionFilterReason.mocked,
      );
    }
    if (!hasValidCoordinates(position)) {
      return const GpsPositionFilterResult(
        accepted: false,
        reason: GpsPositionFilterReason.invalidCoordinate,
      );
    }
    if (!position.accuracy.isFinite || position.accuracy <= 0) {
      return const GpsPositionFilterResult(
        accepted: false,
        reason: GpsPositionFilterReason.invalidAccuracy,
      );
    }
    if (isLowAccuracy(position) && !acceptLowAccuracy) {
      return const GpsPositionFilterResult(
        accepted: false,
        reason: GpsPositionFilterReason.lowAccuracy,
      );
    }
    if (now.difference(position.timestamp).abs() > maxTimestampAge) {
      return const GpsPositionFilterResult(
        accepted: false,
        reason: GpsPositionFilterReason.staleTimestamp,
      );
    }

    final previous = _lastAccepted;
    double? previousAccuracyMeters;
    double? distanceMeters;
    double? elapsedSeconds;
    var acceptedReason = GpsPositionFilterReason.accepted;
    if (previous != null) {
      previousAccuracyMeters = previous.accuracy;
      final previousElapsed = _lastAcceptedElapsed;
      elapsedSeconds = receivedElapsed != null && previousElapsed != null
          ? (receivedElapsed - previousElapsed).inMicroseconds / 1000000
          : position.timestamp.difference(previous.timestamp).inMicroseconds /
              1000000;
      distanceMeters = Geolocator.distanceBetween(
        previous.latitude,
        previous.longitude,
        position.latitude,
        position.longitude,
      );
      if (elapsedSeconds <= 0) {
        return GpsPositionFilterResult(
          accepted: false,
          reason: GpsPositionFilterReason.nonMonotonic,
          previousAccuracyMeters: previousAccuracyMeters,
          distanceMeters: distanceMeters,
          elapsedSeconds: elapsedSeconds,
        );
      }
      // 低精度fixの見かけ上の位置飛びはロバストKalman側でinnovationを
      // 重み下げ・棄却する。入力側だけでなく基準側が低精度な
      // 場合も、ここで先に落とすと良好な後続fixへの再捕捉が止まる。
      if (distanceMeters / elapsedSeconds > maxSpeedMetersPerSecond) {
        final currentIsLowAccuracy = isLowAccuracy(position);
        final previousIsLowAccuracy = isLowAccuracy(previous);
        if (!acceptLowAccuracy ||
            (!currentIsLowAccuracy && !previousIsLowAccuracy)) {
          // 精度の良い新位置が連続しても、古いanchorとの速度だけで
          // 永久に棄却し続けると、端末の再測位後に地図・記録・警告が
          // 止まり得る。古いanchorとは独立に、新位置側の候補間が
          // 現実的な速度で連続した場合だけ有限時間で再捕捉する。
          final reacquired = _recordReacquisitionCandidate(
            position,
            receivedElapsed: receivedElapsed,
          );
          if (reacquired) {
            _lastAccepted = position;
            _lastAcceptedElapsed = receivedElapsed;
            return GpsPositionFilterResult(
              accepted: true,
              reason: GpsPositionFilterReason.accepted,
              speedAnchorReacquired: true,
              previousAccuracyMeters: previousAccuracyMeters,
              distanceMeters: distanceMeters,
              elapsedSeconds: elapsedSeconds,
            );
          }
          return GpsPositionFilterResult(
            accepted: false,
            reason: GpsPositionFilterReason.implausibleSpeed,
            previousAccuracyMeters: previousAccuracyMeters,
            distanceMeters: distanceMeters,
            elapsedSeconds: elapsedSeconds,
          );
        }
        acceptedReason = previousIsLowAccuracy
            ? GpsPositionFilterReason.lowAccuracyAnchorBypassed
            : GpsPositionFilterReason.lowAccuracyMeasurementBypassed;
      }
    }

    _clearPendingReacquisition();
    _lastAccepted = position;
    _lastAcceptedElapsed = receivedElapsed;
    return GpsPositionFilterResult(
      accepted: true,
      reason: acceptedReason,
      previousAccuracyMeters: previousAccuracyMeters,
      distanceMeters: distanceMeters,
      elapsedSeconds: elapsedSeconds,
    );
  }

  bool _recordReacquisitionCandidate(
    Position position, {
    Duration? receivedElapsed,
  }) {
    final pending = _pendingReacquisition;
    if (pending == null) {
      _startPendingReacquisition(position, receivedElapsed);
      return false;
    }

    final pendingElapsed = _pendingReacquisitionElapsed;
    final elapsedSeconds = receivedElapsed != null && pendingElapsed != null
        ? (receivedElapsed - pendingElapsed).inMicroseconds / 1000000
        : position.timestamp.difference(pending.timestamp).inMicroseconds /
            1000000;
    final maximumGapSeconds =
        maximumReacquisitionSampleGap.inMicroseconds / 1000000;
    final distanceMeters = Geolocator.distanceBetween(
      pending.latitude,
      pending.longitude,
      position.latitude,
      position.longitude,
    );
    if (elapsedSeconds <= 0 ||
        elapsedSeconds > maximumGapSeconds ||
        distanceMeters / elapsedSeconds > maxSpeedMetersPerSecond) {
      // 候補列に一貫性がない場合は、今回を新しい1点目とする。
      // 古い候補を残すと、散発的なジャンプで誤再捕捉し得る。
      _startPendingReacquisition(position, receivedElapsed);
      return false;
    }

    _pendingReacquisition = position;
    _pendingReacquisitionElapsed = receivedElapsed;
    _pendingReacquisitionCount += 1;
    if (_pendingReacquisitionCount < reacquisitionSampleCount) return false;
    _clearPendingReacquisition();
    return true;
  }

  void _startPendingReacquisition(Position position, Duration? elapsed) {
    _pendingReacquisition = position;
    _pendingReacquisitionElapsed = elapsed;
    _pendingReacquisitionCount = 1;
  }

  void _clearPendingReacquisition() {
    _pendingReacquisition = null;
    _pendingReacquisitionElapsed = null;
    _pendingReacquisitionCount = 0;
  }
}
