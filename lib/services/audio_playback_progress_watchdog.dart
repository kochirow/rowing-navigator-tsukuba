/// OS上では再生中のままでも、音声割込みで実際の再生位置が止まるケースを
/// 検出するための軽量watchdog。
class AudioPlaybackProgressWatchdog {
  final Duration stallThreshold;

  Duration? _lastPosition;
  DateTime? _lastProgressAt;

  AudioPlaybackProgressWatchdog({
    this.stallThreshold = const Duration(seconds: 3),
  });

  void start(DateTime now) {
    _lastPosition = null;
    _lastProgressAt = now;
  }

  void recordProgress(Duration position, DateTime now) {
    final previous = _lastPosition;
    // ループ終端で位置が0へ戻る変化も進行として扱う。
    if (previous == null || position != previous) {
      _lastProgressAt = now;
    }
    _lastPosition = position;
  }

  /// アプリ管理のループが正常に次周へ移ったことを記録する。
  ///
  /// `completed` は故障ではなく、0.5〜1.4秒の読み上げをもう一度鳴らすための
  /// 正常な境界である。次周の最初のonPositionChangedを待つと、端末によっては
  /// 通知が遅れ、watchdogが正常な周回を停滞と誤認しうるためここで基準時刻を
  /// 更新する。
  void recordLoopRestart(DateTime now) {
    _lastPosition = Duration.zero;
    _lastProgressAt = now;
  }

  bool isStalled(DateTime now) {
    final lastProgressAt = _lastProgressAt;
    return lastProgressAt != null &&
        now.difference(lastProgressAt) >= stallThreshold;
  }

  void reset() {
    _lastPosition = null;
    _lastProgressAt = null;
  }
}
