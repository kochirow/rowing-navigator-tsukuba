import 'dart:async';

/// 長時間動作するplatform streamを、error/done/無通知停止から自動復旧する。
///
/// 同時購読は常に1本だけにし、停止後の古いcallbackはgenerationで無視する。
class ResilientStreamSupervisor<T> {
  final List<Duration> retryBackoff;
  final Duration? silenceTimeout;
  final Duration subscriptionCancelTimeout;

  Stream<T> Function()? _streamFactory;
  void Function(T value)? _onData;
  void Function(Object error, StackTrace stackTrace)? _onError;
  StreamSubscription<T>? _subscription;
  Timer? _retryTimer;
  Timer? _silenceTimer;
  var _retryAttempt = 0;
  var _generation = 0;
  var _running = false;

  ResilientStreamSupervisor({
    this.retryBackoff = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
    ],
    this.silenceTimeout,
    this.subscriptionCancelTimeout = const Duration(seconds: 2),
  })  : assert(retryBackoff.isNotEmpty),
        assert(retryBackoff.every((duration) => !duration.isNegative)),
        assert(silenceTimeout == null || silenceTimeout > Duration.zero),
        assert(subscriptionCancelTimeout > Duration.zero);

  bool get isRunning => _running;
  int get retryAttempt => _retryAttempt;

  Future<void> start({
    required Stream<T> Function() streamFactory,
    required void Function(T value) onData,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) async {
    await stop();
    _streamFactory = streamFactory;
    _onData = onData;
    _onError = onError;
    _running = true;
    _retryAttempt = 0;
    _generation += 1;
    await _connect(_generation);
  }

  Future<void> stop() async {
    _running = false;
    _generation += 1;
    _retryTimer?.cancel();
    _retryTimer = null;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    final subscription = _subscription;
    _subscription = null;
    await _cancelBestEffort(subscription);
  }

  bool _isCurrent(int generation) => _running && generation == _generation;

  Future<void> _connect(int generation) async {
    if (!_isCurrent(generation)) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    final previous = _subscription;
    _subscription = null;
    await _cancelBestEffort(previous, generation: generation);
    if (!_isCurrent(generation)) return;

    try {
      final stream = _streamFactory!.call();
      _subscription = stream.listen(
        (value) {
          if (!_isCurrent(generation)) return;
          _retryAttempt = 0;
          _retryTimer?.cancel();
          _retryTimer = null;
          _armSilenceTimer(generation);
          _onData?.call(value);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!_isCurrent(generation)) return;
          _notifyError(error, stackTrace);
          _scheduleReconnect(generation);
        },
        onDone: () {
          if (!_isCurrent(generation)) return;
          final error = StateError('位置情報streamが終了しました。');
          _notifyError(error, StackTrace.current);
          _scheduleReconnect(generation);
        },
        cancelOnError: false,
      );
      _armSilenceTimer(generation);
    } catch (error, stackTrace) {
      if (!_isCurrent(generation)) return;
      _notifyError(error, stackTrace);
      _scheduleReconnect(generation);
    }
  }

  void _armSilenceTimer(int generation) {
    _silenceTimer?.cancel();
    final timeout = silenceTimeout;
    if (timeout == null) return;
    _silenceTimer = Timer(timeout, () {
      if (!_isCurrent(generation)) return;
      final error = TimeoutException(
        '位置情報streamが${timeout.inSeconds}秒更新されませんでした。',
        timeout,
      );
      _notifyError(error, StackTrace.current);
      _scheduleReconnect(generation);
    });
  }

  void _scheduleReconnect(int generation) {
    if (!_isCurrent(generation) || _retryTimer?.isActive == true) return;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    final index = _retryAttempt.clamp(0, retryBackoff.length - 1).toInt();
    _retryAttempt += 1;
    _retryTimer = Timer(retryBackoff[index], () {
      _retryTimer = null;
      if (_isCurrent(generation)) unawaited(_connect(generation));
    });
  }

  void _notifyError(Object error, StackTrace stackTrace) {
    try {
      _onError?.call(error, stackTrace);
    } catch (_) {
      // 状態通知の失敗で自動復旧を止めない。
    }
  }

  Future<void> _cancelBestEffort(
    StreamSubscription<T>? subscription, {
    int? generation,
  }) async {
    if (subscription == null) return;
    try {
      await subscription.cancel().timeout(subscriptionCancelTimeout);
    } catch (error, stackTrace) {
      // 古い購読callbackはgenerationで無視できる。cancel異常だけで
      // 新しい購読や停止処理全体を永久停止させない。
      if (generation == null || _isCurrent(generation)) {
        _notifyError(error, stackTrace);
      }
    }
  }
}
