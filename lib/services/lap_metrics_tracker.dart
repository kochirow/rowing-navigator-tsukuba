/// 航行中の計器の下半分(距離・chrono・count)の「リセットからの値」を持つ。
///
/// **表示専用。** 練習の記録(`Session`)・安全判定・位置共有には一切関わらない。
/// RESET は表示を0に戻すだけで、記録は練習全体のまま残り、記録画面では
/// リセットの有無に関係なく全体を見られる(2026-09-26 利用者の要件)。
///
/// - 距離: 練習全体の距離(`UseNavigator.totalDistance`)から、リセット時点の値を引く。
/// - chrono: **漕いでいる時間**。推定速度が [movingSpeedThreshold] 以上の間だけ
///   測位の間隔を積む。測位の空白が [maxFixGap] を超えた区間は積まない
///   (データの欠けを「漕いでいた」ことにしない。原則6)。
/// - count: 1本ごとの解析結果の区切り時刻(`latestStrokeBoundary`)が進んだ回数。
///   NK SpeedCoach の COUNT(リセットからの本数)と同じ意味。
class LapMetricsTracker {
  LapMetricsTracker({
    this.movingSpeedThreshold = 0.8,
    this.maxFixGap = const Duration(seconds: 5),
  });

  /// 漕いでいるとみなす速度 [m/s]。既定は安定停止から抜ける速度
  /// (`AlertPresentationConfig.stableStopExitSpeedMetersPerSecond` = 0.8)。
  final double movingSpeedThreshold;

  /// これより長い測位の空白は chrono に積まない。
  final Duration maxFixGap;

  double _totalDistance = 0;
  int _rowingMilliseconds = 0;
  int _strokes = 0;
  DateTime? _lastFixAt;
  DateTime? _lastStrokeBoundary;

  _LapOffset _offset = const _LapOffset.zero();
  _LapOffset? _beforeReset;

  /// 測位1回ぶん。[at] は測位の時刻、[speedMetersPerSecond] は推定速度、
  /// [totalDistanceMeters] は練習全体の距離。
  void onPosition({
    required DateTime at,
    required double speedMetersPerSecond,
    required double totalDistanceMeters,
  }) {
    final last = _lastFixAt;
    if (last != null && at.isAfter(last)) {
      final gap = at.difference(last);
      if (gap <= maxFixGap &&
          speedMetersPerSecond.isFinite &&
          speedMetersPerSecond >= movingSpeedThreshold) {
        _rowingMilliseconds += gap.inMilliseconds;
      }
    }
    if (last == null || at.isAfter(last)) _lastFixAt = at;
    if (totalDistanceMeters.isFinite && totalDistanceMeters >= 0) {
      _totalDistance = totalDistanceMeters;
    }
  }

  /// 1本ごとの解析結果が届いたとき。同じ区切りを2度数えない。
  void onStroke(DateTime strokeBoundary) {
    final last = _lastStrokeBoundary;
    if (last != null && !strokeBoundary.isAfter(last)) return;
    _lastStrokeBoundary = strokeBoundary;
    _strokes++;
  }

  /// 表示を0にする。直前の状態は [undoReset] で1回だけ戻せる。
  void reset() {
    _beforeReset = _offset;
    _offset = _LapOffset(
      distanceMeters: _totalDistance,
      rowingMilliseconds: _rowingMilliseconds,
      strokes: _strokes,
    );
  }

  /// 直前の RESET を取り消す。取り消せたら true。
  bool undoReset() {
    final previous = _beforeReset;
    if (previous == null) return false;
    _offset = previous;
    _beforeReset = null;
    return true;
  }

  /// 新しい練習(航行開始)で、すべてを0から数え直す。
  void restart() {
    _totalDistance = 0;
    _rowingMilliseconds = 0;
    _strokes = 0;
    _lastFixAt = null;
    _lastStrokeBoundary = null;
    _offset = const _LapOffset.zero();
    _beforeReset = null;
  }

  /// リセットからの距離 [m]。
  int get lapDistanceMeters => (_totalDistance - _offset.distanceMeters)
      .clamp(0, double.infinity)
      .round();

  /// リセットからの漕いでいる時間 [秒]。
  int get lapRowingSeconds =>
      ((_rowingMilliseconds - _offset.rowingMilliseconds) ~/ 1000)
          .clamp(0, 1 << 31);

  /// リセットからの本数。
  int get lapStrokes => (_strokes - _offset.strokes).clamp(0, 1 << 31);
}

class _LapOffset {
  const _LapOffset({
    required this.distanceMeters,
    required this.rowingMilliseconds,
    required this.strokes,
  });

  const _LapOffset.zero()
      : distanceMeters = 0,
        rowingMilliseconds = 0,
        strokes = 0;

  final double distanceMeters;
  final int rowingMilliseconds;
  final int strokes;
}
