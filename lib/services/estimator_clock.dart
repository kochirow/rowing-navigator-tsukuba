import '../config/navigator_config.dart';

/// Kalman推定器へ渡す単調時刻を決める純Dart部品。
///
/// 既定ではGNSSの測位時刻を基準にする。処理時刻(Stopwatch)を使うと、OSの
/// バッファリングとイベントループ遅延のジッタ(0〜数百ms)がそのまま dt 誤差に
/// なり、速度推定のバイアスと進行方向への位置遅れを生む。
///
/// 端末時計の自動補正・逆行、測位時刻の異常が疑われる場合だけ、従来どおり
/// 単調な処理時刻へ退避して原点を取り直す。戻り値は必ず前回より大きい。
/// 推定器は逆行・同時刻のfixを丸ごと捨てるため、単調性が崩れるとその測位が
/// 安全判定から欠落してしまう。
class EstimatorClock {
  final bool useGnssTimestamp;
  final double maxDriftSeconds;

  DateTime? _origin;
  Duration? _lastResolved;

  EstimatorClock({
    this.useGnssTimestamp = useGnssTimestampForEstimator,
    this.maxDriftSeconds = maxGnssProcessingClockDriftSeconds,
  }) : assert(maxDriftSeconds > 0);

  /// 直近に返した単調時刻。まだ一度も解決していなければnull。
  Duration? get lastResolved => _lastResolved;

  /// GNSS時刻を基準に採用できているか(診断・テスト用)。
  bool get isTrackingGnssTimestamp => useGnssTimestamp && _origin != null;

  void reset() {
    _origin = null;
    _lastResolved = null;
  }

  /// [fixTimestamp] の測位に対して推定器へ渡す単調時刻を返す。
  ///
  /// [processElapsed] は航行用Stopwatchの経過時間(必ず単調増加)。
  Duration resolve({
    required DateTime fixTimestamp,
    required Duration processElapsed,
  }) {
    var resolved = processElapsed;
    if (useGnssTimestamp) {
      final origin = _origin;
      if (origin == null) {
        _origin = fixTimestamp.subtract(processElapsed);
      } else {
        final candidate = fixTimestamp.difference(origin);
        final driftSeconds =
            (candidate - processElapsed).inMilliseconds.abs() / 1000.0;
        if (candidate > Duration.zero && driftSeconds <= maxDriftSeconds) {
          resolved = candidate;
        } else {
          // 時計が飛んだ・戻った。原点を取り直し、次のfixから復帰する。
          _origin = fixTimestamp.subtract(processElapsed);
        }
      }
    }

    final previous = _lastResolved;
    if (previous != null && resolved <= previous) {
      resolved = processElapsed > previous
          ? processElapsed
          : previous + const Duration(milliseconds: 1);
    }
    _lastResolved = resolved;
    return resolved;
  }

  /// GNSS欠測中の予測時刻を、次の実測fixと同じ単調軸へ載せる。
  Duration resolvePrediction(Duration processElapsed) {
    final previous = _lastResolved;
    final resolved = previous == null || processElapsed > previous
        ? processElapsed
        : previous + const Duration(milliseconds: 1);
    _lastResolved = resolved;
    return resolved;
  }
}
