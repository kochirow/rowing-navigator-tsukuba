import 'dart:async';

/// 非同期送信を同時に1件だけ実行し、待機中の値は常に最新1件へ置き換える。
///
/// Realtime Databaseのwriteは圏外中にACK待ちとなり得る。GPS処理側は
/// [add]だけを呼んで直ちに戻り、このクラスだけがACKを待つことで、通信断が
/// 端末内の危険判定や記録を止めないようにする。
class LatestOnlyAsyncPublisher<T> {
  final Future<void> Function(T value) _publish;
  final Duration ackTimeout;

  /// 直前writeのACK/失敗完了から次のwrite開始までの最小間隔。
  ///
  /// オフライン中に保留されたRTDB writeは、再接続時のserver timestampと
  /// ACKがほぼ同時になる。完了直後にpendingを送るとRulesの更新間隔制限へ
  /// 抵触するため、write開始時刻ではなく完了時刻からpaceする。
  final Duration minPublishInterval;
  final List<Duration> retryBackoff;
  final void Function(T value)? onSuccess;
  final void Function(T value, Object error, StackTrace stackTrace)? onFailure;
  final void Function(T value)? onAckTimeout;

  _PendingValue<T>? _pending;
  bool _accepting = false;
  bool _draining = false;
  int _session = 0;
  int _failureStreak = 0;
  Timer? _ackTimer;
  Timer? _retryTimer;
  Completer<void>? _retryWaiter;
  final Stopwatch _clock = Stopwatch();
  Duration? _lastPublishCompletedAt;

  LatestOnlyAsyncPublisher({
    required Future<void> Function(T value) publish,
    this.ackTimeout = const Duration(seconds: 5),
    this.minPublishInterval = Duration.zero,
    this.retryBackoff = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
    ],
    this.onSuccess,
    this.onFailure,
    this.onAckTimeout,
  })  : assert(!ackTimeout.isNegative),
        assert(!minPublishInterval.isNegative),
        assert(retryBackoff.isNotEmpty),
        assert(retryBackoff.every((duration) => !duration.isNegative)),
        _publish = publish;

  bool get isAccepting => _accepting;
  bool get hasInFlight => _draining;
  bool get hasPending => _pending != null;

  /// 新しい航行セッションの値を受け付ける。
  ///
  /// 前セッションの完了待ちwriteはキャンセルできないが、完了後に古い
  /// callbackや次の古いwriteを発生させない。新セッションの最新値は、
  /// 前writeの完了後に送られる。
  void start() {
    _session += 1;
    _accepting = true;
    _pending = null;
    _failureStreak = 0;
    _lastPublishCompletedAt = null;
    _clock
      ..reset()
      ..start();
    _cancelAckTimer();
    _cancelRetryWait();
  }

  /// 最新値を登録して直ちに戻る。非同期送信の完了は待たない。
  void add(T value) {
    if (!_accepting) return;
    _pending = _PendingValue(value);
    _ensureDrain();
  }

  /// 新規値の受付と再試行を止め、待機中の値を破棄する。
  ///
  /// 実行中のplatform write自体はキャンセルできない。呼出側はこの直後に
  /// 同じFirebase接続へdelete/updateを発行し、write順序の最後を削除にする。
  void stop() {
    _accepting = false;
    _session += 1;
    _pending = null;
    _failureStreak = 0;
    _cancelAckTimer();
    _cancelRetryWait();
  }

  void _ensureDrain() {
    if (_draining || !_accepting || _pending == null) return;
    _draining = true;
    final drainSession = _session;
    unawaited(_drain(drainSession).whenComplete(() {
      _draining = false;
      if (_accepting && _pending != null) _ensureDrain();
    }));
  }

  Future<void> _drain(int drainSession) async {
    while (_accepting && drainSession == _session) {
      final pending = _pending;
      if (pending == null) return;
      _pending = null;
      final value = pending.value;

      await _paceAfterPreviousCompletion(drainSession);
      if (!_isCurrent(drainSession)) return;

      _startAckTimer(value, drainSession);
      try {
        await _publish(value);
        _lastPublishCompletedAt = _clock.elapsed;
        _cancelAckTimer();
        if (!_isCurrent(drainSession)) return;
        _failureStreak = 0;
        _notifySuccess(value);
      } catch (error, stackTrace) {
        _lastPublishCompletedAt = _clock.elapsed;
        _cancelAckTimer();
        if (!_isCurrent(drainSession)) return;
        _failureStreak += 1;
        _notifyFailure(value, error, stackTrace);
        await _waitBeforeRetry(_retryDelayFor(_failureStreak));
        if (!_isCurrent(drainSession)) return;
        // backoff中に新しい測位が来なかった場合だけ、失敗値を
        // 再試行する。新しい測位があれば常にそちらを優先する。
        _pending ??= _PendingValue(value);
      }
    }
  }

  bool _isCurrent(int drainSession) => _accepting && drainSession == _session;

  Future<void> _paceAfterPreviousCompletion(int drainSession) async {
    final completedAt = _lastPublishCompletedAt;
    if (completedAt == null || minPublishInterval == Duration.zero) return;
    final remaining = minPublishInterval - (_clock.elapsed - completedAt);
    if (remaining <= Duration.zero) return;
    await _waitBeforeRetry(remaining);
    if (!_isCurrent(drainSession)) return;
  }

  Duration _retryDelayFor(int failureStreak) {
    final index = (failureStreak - 1).clamp(0, retryBackoff.length - 1).toInt();
    return retryBackoff[index];
  }

  void _startAckTimer(T value, int drainSession) {
    _cancelAckTimer();
    if (ackTimeout == Duration.zero) {
      scheduleMicrotask(() {
        if (_isCurrent(drainSession)) _notifyAckTimeout(value);
      });
      return;
    }
    _ackTimer = Timer(ackTimeout, () {
      if (_isCurrent(drainSession)) _notifyAckTimeout(value);
    });
  }

  void _cancelAckTimer() {
    _ackTimer?.cancel();
    _ackTimer = null;
  }

  Future<void> _waitBeforeRetry(Duration duration) {
    _cancelRetryWait();
    final waiter = Completer<void>();
    _retryWaiter = waiter;
    if (duration == Duration.zero) {
      scheduleMicrotask(() {
        if (!waiter.isCompleted) waiter.complete();
      });
    } else {
      _retryTimer = Timer(duration, () {
        if (!waiter.isCompleted) waiter.complete();
      });
    }
    return waiter.future.whenComplete(() {
      if (identical(_retryWaiter, waiter)) {
        _retryWaiter = null;
        _retryTimer = null;
      }
    });
  }

  void _cancelRetryWait() {
    _retryTimer?.cancel();
    _retryTimer = null;
    final waiter = _retryWaiter;
    _retryWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  void _notifySuccess(T value) {
    try {
      onSuccess?.call(value);
    } catch (_) {
      // UI通知の失敗で送信キューを停止させない。
    }
  }

  void _notifyFailure(T value, Object error, StackTrace stackTrace) {
    try {
      onFailure?.call(value, error, stackTrace);
    } catch (_) {
      // UI通知の失敗で再試行を停止させない。
    }
  }

  void _notifyAckTimeout(T value) {
    try {
      onAckTimeout?.call(value);
    } catch (_) {
      // UI通知の失敗で実行中writeを重複させない。
    }
  }
}

class _PendingValue<T> {
  final T value;

  const _PendingValue(this.value);
}
