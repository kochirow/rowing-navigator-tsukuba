import 'dart:async';

/// 長時間動作するplatform streamを、error/done/無通知停止から自動復旧する。
///
/// 同時購読は常に1本だけにし、停止後の古いcallbackはgenerationで無視する。
class ResilientStreamSupervisor<T> {
  final List<Duration> retryBackoff;
  final Duration? silenceTimeout;

  /// 無通知とみなすまでの時間を、状況に応じて差し替える。
  ///
  /// null を返したときは [silenceTimeout] を使う。
  ///
  /// **なぜ可変にするか。** iOS は端末が止まっているとき、位置更新の配信を
  /// 意図的に絞る。そこへ固定の短い閾値で購読を張り直すと、
  /// `stopUpdatingLocation` → `startUpdatingLocation` の暖機を毎回失い、
  /// 正常な省電力動作を自分で悪化させる。2026-08-05 の実機ログでは
  /// 停止に近づくほど配信間隔が伸び、8秒の閾値で251回の再購読が起きていた。
  ///
  /// **真の途絶の検知は遅らせない。** GPS品質の判定と `gps_unavailable` の
  /// 確定(10秒)はこの値と独立しており、閾値を延ばしても system fault の
  /// タイミングは変わらない。
  final Duration? Function()? silenceTimeoutResolver;

  final Duration subscriptionCancelTimeout;

  Stream<T> Function()? _streamFactory;
  void Function(T value)? _onData;
  void Function(Object error, StackTrace stackTrace)? _onError;
  StreamSubscription<T>? _subscription;
  Timer? _retryTimer;
  Timer? _silenceTimer;
  var _retryAttempt = 0;
  var _generation = 0;
  var _connectionGeneration = 0;
  var _running = false;

  ResilientStreamSupervisor({
    this.retryBackoff = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
    ],
    this.silenceTimeout,
    this.silenceTimeoutResolver,
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
    _connectionGeneration += 1;
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
    // start/stopの世代とは別に、再購読ごとに古いcallbackを
    // 無効化する。platform側のcancelがtimeoutしても、新旧streamの
    // 測位が同じGPSフィルタへ混ざらないための境界である。
    final connectionGeneration = ++_connectionGeneration;
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
          if (!_isCurrentConnection(generation, connectionGeneration)) return;
          _retryAttempt = 0;
          _retryTimer?.cancel();
          _retryTimer = null;
          _armSilenceTimer(generation);
          _onData?.call(value);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!_isCurrentConnection(generation, connectionGeneration)) return;
          _notifyError(error, stackTrace);
          _scheduleReconnect(generation);
        },
        onDone: () {
          if (!_isCurrentConnection(generation, connectionGeneration)) return;
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

  bool _isCurrentConnection(int generation, int connectionGeneration) =>
      _isCurrent(generation) && connectionGeneration == _connectionGeneration;

  void _armSilenceTimer(int generation) {
    _silenceTimer?.cancel();
    // 解決関数が null を返したら既定へ落とす。解決関数の例外で
    // 監視そのものを止めない(原則1)。
    Duration? resolved;
    try {
      resolved = silenceTimeoutResolver?.call();
    } catch (_) {
      resolved = null;
    }
    final timeout = resolved ?? silenceTimeout;
    if (timeout == null || timeout <= Duration.zero) return;
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
