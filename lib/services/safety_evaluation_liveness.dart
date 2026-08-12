/// 1秒タイマーとGPS起点の安全評価を別々に監視するための純粋ロジック。
///
/// GPS入力の途絶は [GpsHealthMonitor] が担当する。一方これは、GPSが
/// 届いているのに衝突評価が完了しない経路と、Timer自身の停止を区別して
/// 診断する。時刻は端末時計の変更を受けない単調経過時間で渡す。
class SafetyEvaluationLiveness {
  final Duration timerStallThreshold;

  /// 評価停止とみなす下限。実効測位間隔がこれより短いときはこの値を使う。
  final Duration evaluationStallThreshold;

  /// 実効測位間隔の何倍を評価停止の閾値にするか。
  ///
  /// **固定の3秒だけでは、正常な運用で fault が立つ。**
  /// 2026-08-06 実機ログ: 2x の1セッションで `lastSafetyEvaluationAgeMs` が
  /// 3002 / 3012 / 3015 / 3190ms となり、6回 fault が立った。
  /// 当時の実効測位間隔は中央値 2.0〜3.0 秒で、**閾値と測位間隔が
  /// ちょうど重なっていた**。正常な運用で鳴る警告は不具合である(原則4)。
  ///
  /// 測位が密なら固定値のまま、疎なら間隔に追随して広がる。
  /// **下限は [evaluationStallThreshold] のままなので、測位が改善したときに
  /// 検出が甘くなることはない。**
  final double evaluationStallIntervalMultiplier;

  Duration? _lastTimerTickAt;
  Duration? _lastSafetyInputAt;
  Duration? _lastSafetyEvaluationCompletedAt;

  /// 直近の安全入力間隔(実効測位間隔)の移動中央値の代用。
  /// 単発の欠測で閾値が跳ねないよう、指数移動平均で滑らかにする。
  Duration? _smoothedInputInterval;

  SafetyEvaluationLiveness({
    required this.timerStallThreshold,
    required this.evaluationStallThreshold,
    this.evaluationStallIntervalMultiplier = 1.5,
  });

  /// いま実際に使っている評価停止の閾値。診断へ残して、
  /// 「測位が疎だから広がったのか」を後から切り分けられるようにする。
  Duration get effectiveEvaluationStallThreshold {
    final interval = _smoothedInputInterval;
    if (interval == null) return evaluationStallThreshold;
    final scaled = Duration(
      microseconds:
          (interval.inMicroseconds * evaluationStallIntervalMultiplier).round(),
    );
    return scaled > evaluationStallThreshold
        ? scaled
        : evaluationStallThreshold;
  }

  /// 診断用の実効測位間隔。
  Duration? get smoothedInputInterval => _smoothedInputInterval;

  Duration? get lastSafetyEvaluationCompletedAt =>
      _lastSafetyEvaluationCompletedAt;

  Duration? lastSafetyEvaluationAgeAt(Duration now) {
    final completedAt = _lastSafetyEvaluationCompletedAt;
    return completedAt == null ? null : _nonNegativeAge(now, completedAt);
  }

  void reset() {
    _lastTimerTickAt = null;
    _lastSafetyInputAt = null;
    _lastSafetyEvaluationCompletedAt = null;
    _smoothedInputInterval = null;
  }

  /// 衝突評価を実行すべき品質のGPS入力を記録する。
  void recordSafetyInput(Duration receivedAt) {
    final previous = _lastSafetyInputAt;
    if (previous != null) {
      final interval = _nonNegativeAge(receivedAt, previous);
      // 長い欠測(橋の下・木立)で閾値が跳ね上がらないよう、
      // 極端な間隔は取り込まない。GPS途絶は GpsHealthMonitor の担当である。
      if (interval > Duration.zero && interval <= _maxTrackedInputInterval) {
        final smoothed = _smoothedInputInterval;
        _smoothedInputInterval = smoothed == null
            ? interval
            : Duration(
                microseconds:
                    ((smoothed.inMicroseconds * 3 + interval.inMicroseconds) /
                            4)
                        .round(),
              );
      }
    }
    _lastSafetyInputAt = receivedAt;
  }

  static const _maxTrackedInputInterval = Duration(seconds: 5);

  /// 衝突評価から提示用スナップショットの反映まで正常完了したときだけ呼ぶ。
  void recordSafetyEvaluationCompleted(Duration completedAt) {
    _lastSafetyEvaluationCompletedAt = completedAt;
  }

  /// 1秒タイマーで現在の生存状態を観測する。
  SafetyEvaluationLivenessTick tick(Duration now) {
    final previousTimerTick = _lastTimerTickAt;
    _lastTimerTickAt = now;
    final timerGap = previousTimerTick == null ? null : now - previousTimerTick;
    final timerStalled = timerGap != null && timerGap > timerStallThreshold;

    final safetyInputAt = _lastSafetyInputAt;
    final safetyInputAge =
        safetyInputAt == null ? null : _nonNegativeAge(now, safetyInputAt);
    final lastEvaluationAge = lastSafetyEvaluationAgeAt(now);
    final threshold = effectiveEvaluationStallThreshold;
    final evaluationStalled = safetyInputAge != null &&
        safetyInputAge <= threshold &&
        (lastEvaluationAge == null || lastEvaluationAge > threshold);

    return SafetyEvaluationLivenessTick(
      timerStalled: timerStalled,
      evaluationStalled: evaluationStalled,
      timerGap: timerGap,
      lastSafetyEvaluationAge: lastEvaluationAge,
      effectiveEvaluationStallThreshold: threshold,
      smoothedInputInterval: _smoothedInputInterval,
    );
  }

  static Duration _nonNegativeAge(Duration now, Duration then) {
    final age = now - then;
    return age.isNegative ? Duration.zero : age;
  }
}

class SafetyEvaluationLivenessTick {
  final bool timerStalled;
  final bool evaluationStalled;
  final Duration? timerGap;
  final Duration? lastSafetyEvaluationAge;

  /// この観測で使った評価停止の閾値。
  final Duration effectiveEvaluationStallThreshold;

  /// そのとき見ていた実効測位間隔。null は未確定。
  final Duration? smoothedInputInterval;

  const SafetyEvaluationLivenessTick({
    required this.timerStalled,
    required this.evaluationStalled,
    required this.timerGap,
    required this.lastSafetyEvaluationAge,
    this.effectiveEvaluationStallThreshold = Duration.zero,
    this.smoothedInputInterval,
  });
}
