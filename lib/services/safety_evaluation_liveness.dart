/// 1秒タイマーとGPS起点の安全評価を別々に監視するための純粋ロジック。
///
/// GPS入力の途絶は [GpsHealthMonitor] が担当する。一方これは、GPSが
/// 届いているのに衝突評価が完了しない経路と、Timer自身の停止を区別して
/// 診断する。時刻は端末時計の変更を受けない単調経過時間で渡す。
class SafetyEvaluationLiveness {
  final Duration timerStallThreshold;
  final Duration evaluationStallThreshold;

  Duration? _lastTimerTickAt;
  Duration? _lastSafetyInputAt;
  Duration? _lastSafetyEvaluationCompletedAt;

  SafetyEvaluationLiveness({
    required this.timerStallThreshold,
    required this.evaluationStallThreshold,
  });

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
  }

  /// 衝突評価を実行すべき品質のGPS入力を記録する。
  void recordSafetyInput(Duration receivedAt) {
    _lastSafetyInputAt = receivedAt;
  }

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
    final evaluationStalled = safetyInputAge != null &&
        safetyInputAge <= evaluationStallThreshold &&
        (lastEvaluationAge == null ||
            lastEvaluationAge > evaluationStallThreshold);

    return SafetyEvaluationLivenessTick(
      timerStalled: timerStalled,
      evaluationStalled: evaluationStalled,
      timerGap: timerGap,
      lastSafetyEvaluationAge: lastEvaluationAge,
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

  const SafetyEvaluationLivenessTick({
    required this.timerStalled,
    required this.evaluationStalled,
    required this.timerGap,
    required this.lastSafetyEvaluationAge,
  });
}
