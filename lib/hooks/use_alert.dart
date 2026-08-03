import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../config/warning_audio_config.dart';
import '../services/audio_playback_progress_watchdog.dart';

enum _AlertPlaybackMode { loop, once }

/// 持続音プレイヤーの直列キューに載せる操作種別。
///
/// stopは安全上の終端操作なので、後続のplay/recoverに追い出させない。
/// recoverは停止・再生要求が待っていないときだけ実行するベストエフォートの
/// 復旧であり、利用者または提示ポリシーの明示的な要求より優先しない。
enum AlertCommandKind { play, stop, recover }

/// 直列キューに載せる1件の再生・停止要求。
class _AlertCommand {
  final AlertCommandKind kind;
  final Future<void> Function() run;
  final Completer<void> _completer;

  _AlertCommand(this.kind, this.run, this._completer);

  void complete() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

/// 持続音プレイヤーの操作を1本ずつ実行する純Dartキュー。
///
/// [AudioPlayer] を直接持たないので、タイムアウトするstopや復旧操作を
/// フェイクで差し替えて検証できる。待機中のplayは最新の状態へ畳む一方、
/// stopは必ず残す。recoverは待機中の操作が1件でもあれば捨てる。
class AlertCommandQueue {
  AlertCommandQueue({this.onCommandError});

  final void Function(Object error, StackTrace stackTrace)? onCommandError;
  final List<_AlertCommand> _pending = <_AlertCommand>[];
  bool _draining = false;
  bool _disposed = false;

  int get pendingCount => _pending.length;

  Future<void> enqueue(
    AlertCommandKind kind,
    Future<void> Function() run,
  ) {
    if (_disposed) return Future<void>.value();

    final command = _AlertCommand(kind, run, Completer<void>());
    switch (kind) {
      case AlertCommandKind.play:
        // 再生の連打は最後の状態だけが意味を持つ。ただしstopは絶対に残す。
        _completeAndRemoveWhere(
          (candidate) =>
              candidate.kind == AlertCommandKind.play ||
              candidate.kind == AlertCommandKind.recover,
        );
        _pending.add(command);
      case AlertCommandKind.stop:
        // stopの後に古いplayが残ると、停止完了直後に鳴り直してしまう。
        // 既に待っているstopは捨てず、すべて実行する。
        _completeAndRemoveWhere(
          (candidate) =>
              candidate.kind == AlertCommandKind.play ||
              candidate.kind == AlertCommandKind.recover,
        );
        _pending.add(command);
      case AlertCommandKind.recover:
        // 復旧は状態を変える本要求ではない。待機操作があれば、より新しい
        // play/stopが正しい状態を作るので黙って譲る。
        if (_pending.isNotEmpty) {
          command.complete();
          return command._completer.future;
        }
        _pending.add(command);
    }
    _startDrainIfNeeded();
    return command._completer.future;
  }

  void clear() {
    _disposed = true;
    for (final command in _pending) {
      command.complete();
    }
    _pending.clear();
  }

  void _completeAndRemoveWhere(bool Function(_AlertCommand) test) {
    final removed = _pending.where(test).toList(growable: false);
    _pending.removeWhere(test);
    for (final command in removed) {
      command.complete();
    }
  }

  void _startDrainIfNeeded() {
    if (_draining) return;
    _draining = true;
    unawaited(Future<void>(() async {
      try {
        while (_pending.isNotEmpty) {
          final next = _pending.removeAt(0);
          try {
            await next.run();
          } catch (error, stackTrace) {
            // 1件の失敗で後続のstop/playを止めない。
            onCommandError?.call(error, stackTrace);
          } finally {
            next.complete();
          }
        }
      } finally {
        _draining = false;
        // finally直後に積まれた操作を取りこぼさない。
        if (_pending.isNotEmpty && !_disposed) _startDrainIfNeeded();
      }
    }));
  }
}

/// 単発合図キューに溜められる最大件数。
///
/// 合図は1件1〜2秒鳴る。無制限に溜めると「もう通り過ぎた場所の合図」が
/// 遅れて鳴り、かえって状況を誤らせる。古いものから捨てて新しい合図を優先し、
/// 捨てたことは `audio_cue_dropped` として必ず残す(黙って落とさない)。
const alertCueMaxPending = 3;

/// 単発合図の重複排除に保持する eventId の上限。
/// 既存の `playedOnceEventIds` と同じ規模に揃える。
const alertCuePlayedEventIdLimit = 256;

/// 単発合図1件の再生完了を待つ上限。
///
/// 完了通知が来ない端末・音声経路でもキューを止めないための安全弁。
/// 合図の音声アセットは1〜2秒なので、これを超えるのは異常である。
const _cuePlaybackTimeout = Duration(seconds: 6);

/// 単発合図1件の要求。
class AlertCueRequest {
  AlertCueRequest(this.assetPath, this.eventId);

  final String assetPath;
  final String eventId;
  final Completer<void> _completer = Completer<void>();

  /// 再生が終わる(または捨てられる)まで待つ。
  Future<void> get done => _completer.future;

  void complete() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

/// [AlertCueQueue.admit] の判定結果。
class AlertCueAdmission {
  const AlertCueAdmission({
    required this.accepted,
    this.rejectReason,
    this.dropped = const <AlertCueRequest>[],
  });

  /// キューへ積めたか。
  final bool accepted;

  /// 積めなかった理由。診断イベントの `reason` へそのまま入れる。
  final String? rejectReason;

  /// 上限超過で捨てた古い要求。呼出側が診断へ出し、待ち手を完了させる。
  final List<AlertCueRequest> dropped;
}

/// 単発合図の重複排除とFIFOキューを担う純Dartロジック。
///
/// [AudioPlayer] を持たないので単体テストできる
/// (`test/hooks/use_alert_cue_test.dart`)。
class AlertCueQueue {
  AlertCueQueue({
    this.maxPending = alertCueMaxPending,
    this.playedEventIdLimit = alertCuePlayedEventIdLimit,
  });

  final int maxPending;
  final int playedEventIdLimit;
  final List<AlertCueRequest> _pending = <AlertCueRequest>[];
  final Set<String> _playedEventIds = <String>{};

  List<AlertCueRequest> get pending =>
      List<AlertCueRequest>.unmodifiable(_pending);

  bool get hasPending => _pending.isNotEmpty;

  /// 積めるかを判定し、積めるなら末尾へ足す。
  ///
  /// 重複排除は**要求時点**で確定させる。再生完了まで判定を遅らせると、
  /// 1Hzで再評価される同じ合図が同じ eventId のままキューへ積み重なる。
  AlertCueAdmission admit(AlertCueRequest request) {
    if (_playedEventIds.contains(request.eventId)) {
      return const AlertCueAdmission(
        accepted: false,
        rejectReason: 'duplicate_event_id',
      );
    }
    _playedEventIds.add(request.eventId);
    if (_playedEventIds.length > playedEventIdLimit) {
      _playedEventIds.remove(_playedEventIds.first);
    }
    _pending.add(request);
    final dropped = <AlertCueRequest>[];
    while (_pending.length > maxPending) {
      dropped.add(_pending.removeAt(0));
    }
    return AlertCueAdmission(accepted: true, dropped: dropped);
  }

  /// FIFOで次の1件を取り出す。
  AlertCueRequest? takeNext() => _pending.isEmpty ? null : _pending.removeAt(0);

  /// 待機中を全て取り出す。停止・破棄で待ち手を放置しないために使う。
  /// 重複排除の記憶は消さない(停止をまたいだ鳴り直しを増やさない)。
  List<AlertCueRequest> takeAll() {
    final all = List<AlertCueRequest>.from(_pending);
    _pending.clear();
    return all;
  }

  /// 重複排除の記憶も含めて初期化する。破棄時にだけ使う。
  void reset() {
    _pending.clear();
    _playedEventIds.clear();
  }
}

/// 警告音が鳴っている間の再生監視周期。停止検出の速さを決める。
const _watchdogActiveInterval = Duration(seconds: 1);

/// 警告が鳴っていない間の監視周期。監視対象が無いので粗くてよい。
/// 警告が始まった時点で [_watchdogActiveInterval] へ戻す。
const _watchdogIdleInterval = Duration(seconds: 5);

typedef AlertDiagnosticCallback = void Function(
  String type,
  Map<String, dynamic> details,
);

UseAlert useAlert({AlertDiagnosticCallback? onDiagnosticEvent}) {
  // useState(AudioPlayer())はrebuildごとに未採用のAudioPlayerまで生成し、
  // native player/channelを解放できない。副作用を持つ資源は1回だけ生成する。
  final initialPlayer = useMemoized(AudioPlayer.new);
  // timeoutが連続したネイティブplayerは捨て、新しいインスタンスへ向け替える。
  final player = useRef<AudioPlayer>(initialPlayer);
  final state = useState<PlayerState>(PlayerState.stopped);
  final error = useState<String?>(null);
  final initialization = useRef<Future<void>?>(null);
  final activeAsset = useRef<String?>(null);
  final activeMode = useRef<_AlertPlaybackMode?>(null);
  final activeEventId = useRef<String?>(null);
  final playedOnceEventIds = useRef(<String>{});
  final requestGeneration = useRef(0);
  final recoveryInFlight = useRef(false);
  final consecutiveRecoveryFailures = useRef(0);
  final consecutivePlatformTimeouts = useRef(0);
  final isDisposed = useRef(false);
  final progressWatchdog = useMemoized(AudioPlaybackProgressWatchdog.new);
  final diagnosticCallback = useRef<AlertDiagnosticCallback?>(
    onDiagnosticEvent,
  );
  diagnosticCallback.value = onDiagnosticEvent;
  // 再生要求の直列化キュー。stopを後続要求に追い出させない。
  final commandQueue = useMemoized(
    () => AlertCommandQueue(
      onCommandError: (error, _) {
        if (kDebugMode) debugPrint('Alert audio command failed: $error');
      },
    ),
  );
  final playerStateSubscription = useRef<StreamSubscription<PlayerState>?>(
    null,
  );
  final playerPositionSubscription = useRef<StreamSubscription<Duration>?>(
    null,
  );
  final playerCompleteSubscription = useRef<StreamSubscription<void>?>(null);
  final playerRecreation = useRef<Future<void>?>(null);
  final recreateAlertPlayer =
      useRef<Future<void> Function({required String reason})?>(null);
  // effect内のwatchdog/recoveryから、後で定義される通常の再生手順へ戻す。
  // playerを作り直した直後はsourceが無いため、resumeだけでは復旧できない。
  final replayWithFreshPlayer = useRef<
      Future<void> Function(
        String assetPath,
        _AlertPlaybackMode mode, {
        String? eventId,
      })?>(null);
  final requestLoopRestart =
      useRef<void Function({required String asset, required int request})?>(
    null,
  );
  final loopRestartPending = useRef(false);

  // ---- 単発合図(cue)専用チャンネル ----
  //
  // 既存の [enqueueCommand] は「待機中の要求を常に最新1件へ置き換える」設計で、
  // 複数の要求を順に鳴らすキューではない。ここへ単発合図を投げると、
  // 鳴っている持続音(岸などの連続音)を止めてしまうか、
  // 合図自身が次の提示に追い越されて捨てられる。実機ログで、検知されていた
  // カーブ・逆走の合図が一度も鳴らなかったのはこれが原因である。
  //
  // 音声セッションは mixWithOthers なので、2本目のプレイヤーを重ねられる。
  // cue側は既存プレイヤーの状態(activeAsset / activeMode / state / error /
  // 再生ウォッチドッグ)を一切触らない。
  final cuePlayer = useMemoized(AudioPlayer.new);
  final cueQueue = useMemoized(AlertCueQueue.new);
  final cueInitialization = useRef<Future<void>?>(null);
  final cueDraining = useRef(false);
  final cueGeneration = useRef(0);
  final cueCompletion = useRef<Completer<void>?>(null);

  String errorMessage(Object error) {
    final message = error.toString();
    return message.length <= 240 ? message : '${message.substring(0, 240)}…';
  }

  void emitDiagnostic(
    String type, [
    Map<String, dynamic> details = const <String, dynamic>{},
  ]) {
    final callback = diagnosticCallback.value;
    if (callback == null) return;
    try {
      callback(type, Map<String, dynamic>.from(details));
    } catch (callbackError) {
      // 診断記録の失敗で警告音の再生を止めない。
      if (kDebugMode) {
        debugPrint('Alert diagnostic callback failed: $callbackError');
      }
    }
  }

  void updatePlayerState(PlayerState next, {String? reason}) {
    final previous = state.value;
    state.value = next;
    if (previous == next) return;
    emitDiagnostic('audio_player_state_changed', {
      'from': previous.name,
      'to': next.name,
      if (reason != null) 'reason': reason,
      if (activeAsset.value != null) 'asset': activeAsset.value,
      if (activeMode.value != null) 'mode': activeMode.value!.name,
      if (activeEventId.value != null) 'eventId': activeEventId.value,
    });
  }

  Future<T> platformCall<T>(String operation, Future<T> Function() run) async {
    try {
      final result = await run().timeout(alertPlatformCallTimeout);
      consecutivePlatformTimeouts.value = 0;
      return result;
    } on TimeoutException {
      consecutivePlatformTimeouts.value += 1;
      emitDiagnostic('audio_platform_call_timeout', {
        'operation': operation,
        'timeoutMs': alertPlatformCallTimeout.inMilliseconds,
        'consecutiveFailureCount': consecutivePlatformTimeouts.value,
      });
      rethrow;
    }
  }

  Future<void> applyAudioContext({
    required String reason,
    AudioPlayer? target,
  }) async {
    // iOSの音声contextはplayer単位ではなくアプリ全体へ反映される。
    // Buddycomなどが先に通話sessionを開始している場合にも、再生直前と
    // 割込み復旧時にmix可能なcategoryを再適用する。
    await platformCall(
      'setAudioContext',
      () => (target ?? player.value).setAudioContext(
        createWarningAudioContextConfig().build(),
      ),
    );
    emitDiagnostic('audio_context_applied', {
      'reason': reason,
      'focus': 'mixWithOthers',
      'respectSilence': false,
      'stayAwake': true,
    });
  }

  useEffect(() {
    isDisposed.value = false;
    Timer? playbackWatchdog;
    Future<void> initializePlayer(AudioPlayer target) async {
      emitDiagnostic('audio_initialization_started');
      try {
        // Buddycomなどの通話を止めたり下げたりせず、警告音を重ねる。
        // サイレントスイッチ中も警告音は再生する。
        await applyAudioContext(reason: 'initialization', target: target);
        // 短さよりもループ再生の安定性を優先してmediaPlayerを使う。
        await platformCall(
          'setPlayerMode',
          () => target.setPlayerMode(PlayerMode.mediaPlayer),
        );
        // 連続音もアプリ側でonPlayerCompleteを受けて鳴り直す。ネイティブの
        // loopと二重に管理すると、iOSのcompleted通知を故障と誤認する。
        await platformCall(
          'setReleaseMode',
          () => target.setReleaseMode(ReleaseMode.stop),
        );
        await AudioCache.instance.loadAll(warningAudioAssets);
        emitDiagnostic('audio_initialization_succeeded', {
          'playerMode': PlayerMode.mediaPlayer.name,
          'assetCount': warningAudioAssets.length,
        });
      } catch (e) {
        if (!isDisposed.value) {
          error.value = '警告音の準備に失敗しました。端末の音声設定を確認してください。';
        }
        emitDiagnostic('audio_initialization_failed', {
          'errorType': e.runtimeType.toString(),
          'errorMessage': errorMessage(e),
        });
        if (kDebugMode) debugPrint('Alert audio initialization error: $e');
      }
    }

    Future<void> cancelPlayerSubscriptions() async {
      await playerStateSubscription.value?.cancel();
      await playerPositionSubscription.value?.cancel();
      await playerCompleteSubscription.value?.cancel();
      playerStateSubscription.value = null;
      playerPositionSubscription.value = null;
      playerCompleteSubscription.value = null;
    }

    void attachPlayerSubscriptions(AudioPlayer target) {
      playerStateSubscription.value =
          target.onPlayerStateChanged.listen((next) {
        if (isDisposed.value || !identical(target, player.value)) return;
        updatePlayerState(next, reason: 'player_event');
        if (next == PlayerState.playing) {
          consecutiveRecoveryFailures.value = 0;
          error.value = null;
        }
        // completedは故障ではない。自前ループの次周を要求する正常通知として
        // 扱う。onPlayerCompleteと二重に届いてもrequest側で1件へ畳まれる。
        if (next == PlayerState.completed &&
            activeMode.value == _AlertPlaybackMode.loop &&
            activeAsset.value != null) {
          requestLoopRestart.value?.call(
            asset: activeAsset.value!,
            request: requestGeneration.value,
          );
        }
      });
      playerPositionSubscription.value =
          target.onPositionChanged.listen((position) {
        if (!isDisposed.value &&
            identical(target, player.value) &&
            activeAsset.value != null) {
          progressWatchdog.recordProgress(position, DateTime.now());
        }
      });
      playerCompleteSubscription.value = target.onPlayerComplete.listen((_) {
        if (isDisposed.value || !identical(target, player.value)) return;
        if (activeMode.value == _AlertPlaybackMode.loop &&
            activeAsset.value != null) {
          requestLoopRestart.value?.call(
            asset: activeAsset.value!,
            request: requestGeneration.value,
          );
        }
      });
    }

    attachPlayerSubscriptions(player.value);
    initialization.value = initializePlayer(player.value);

    Future<void> replacePlayer({required String reason}) async {
      final existing = playerRecreation.value;
      if (existing != null) return existing;
      late final Future<void> task;
      task = Future<void>(() async {
        final oldPlayer = player.value;
        final replacement = AudioPlayer();
        // timeoutした古いインスタンスには二度と触らない。disposeも待たずに
        // 放流し、新しいplayerへすべての以降操作を向ける。
        await cancelPlayerSubscriptions();
        player.value = replacement;
        attachPlayerSubscriptions(replacement);
        // 古いネイティブplayerの状態イベントを、新しいplayerの状態として
        // 扱わない。特にloopのrestart/recoveryがtimeoutした後は、再作成した
        // playerにはsourceが設定されていないため、playingのまま残すと以降の
        // play要求が「既に再生中」と誤認して無音のままになる。
        progressWatchdog.reset();
        updatePlayerState(PlayerState.stopped, reason: 'player_recreated');
        unawaited(oldPlayer.dispose().catchError((Object disposeError) {
          if (kDebugMode) {
            debugPrint('Timed-out audio player disposal error: $disposeError');
          }
        }));
        initialization.value = initializePlayer(replacement);
        try {
          await initialization.value;
          if (!isDisposed.value && identical(replacement, player.value)) {
            consecutivePlatformTimeouts.value = 0;
            emitDiagnostic('audio_player_recreated', {'reason': reason});
          }
        } catch (recreateError) {
          if (!isDisposed.value && identical(replacement, player.value)) {
            error.value = '警告音を再初期化できません。端末の音声設定を確認してください。';
          }
          emitDiagnostic('audio_player_recreate_failed', {
            'reason': reason,
            'errorType': recreateError.runtimeType.toString(),
            'errorMessage': errorMessage(recreateError),
          });
          rethrow;
        }
      });
      playerRecreation.value = task;
      try {
        await task;
      } finally {
        if (identical(playerRecreation.value, task)) {
          playerRecreation.value = null;
        }
      }
    }

    recreateAlertPlayer.value = replacePlayer;

    // cueの再生完了通知。キューを次の1件へ進めるためだけに使う。
    final cueCompleteSubscription = cuePlayer.onPlayerComplete.listen((_) {
      final completion = cueCompletion.value;
      if (completion != null && !completion.isCompleted) completion.complete();
    });

    Future<void> initializeCue() async {
      try {
        // 音声contextはplayer単位ではなくアプリ全体へ効くため、既存プレイヤーと
        // 同一の設定を使う。同じ設定なので、cue側の適用が持続音のsessionを
        // 変えることはない。適用は初期化時の1回だけにして、既存プレイヤーが
        // 再生ごとに出す `audio_context_applied` の系列を汚さない。
        await cuePlayer.setAudioContext(
          createWarningAudioContextConfig().build(),
        );
        await cuePlayer.setPlayerMode(PlayerMode.mediaPlayer);
        // 合図は単発。ループさせない。
        await cuePlayer.setReleaseMode(ReleaseMode.stop);
        // アセットの事前ロードは AudioCache.instance がプロセス全体で共有する
        // ため、既存プレイヤーの初期化で済んでいる。
      } catch (e) {
        // cueの失敗で error.value を汚さない。ここを汚すと
        // 「警告音を再生できません」の system fault が立ち、
        // 持続音の系が cue の都合で壊れる。診断にだけ残す。
        emitDiagnostic('audio_cue_failed', {
          'reason': 'initialization_failed',
          'errorType': e.runtimeType.toString(),
          'errorMessage': errorMessage(e),
        });
        if (kDebugMode) debugPrint('Alert cue audio initialization error: $e');
      }
    }

    cueInitialization.value = initializeCue();

    // OS割込や音声経路変更でループが止まっても、警告がactiveなら復旧する。
    // stop()は先にactiveAssetをnullへするため、意図した停止は再開しない。
    //
    // 警告が鳴っていない間は監視対象が無いので、1秒ではなくアイドル周期で
    // 回す。警告が始まった瞬間に1秒周期へ戻すので、復旧の速さは変わらない。
    //
    // **cueプレイヤーはこの監視の対象外**。監視は「鳴り続けるはずの音が
    // 止まった」ことを検出する仕組みで、1〜2秒で終わる単発合図には
    // 意味がない。復旧を試みる頃には正常に鳴り終わっており、
    // 鳴り直しは「同じ合図が二度鳴る」過剰警告になる(原則4)。
    // 合図が届かなかった場合は `audio_cue_failed` で記録に残す。
    late void Function(Duration) schedulePlaybackWatchdog;
    var watchdogInterval = _watchdogIdleInterval;
    void runPlaybackWatchdogTick() {
      final asset = activeAsset.value;
      final mode = activeMode.value;
      final desiredInterval =
          asset == null ? _watchdogIdleInterval : _watchdogActiveInterval;
      if (desiredInterval != watchdogInterval) {
        watchdogInterval = desiredInterval;
        schedulePlaybackWatchdog(desiredInterval);
      }
      final now = DateTime.now();
      final playbackStalled =
          state.value == PlayerState.playing && progressWatchdog.isStalled(now);
      if (isDisposed.value ||
          asset == null ||
          mode == null ||
          mode == _AlertPlaybackMode.once ||
          (state.value == PlayerState.playing && !playbackStalled) ||
          recoveryInFlight.value) {
        return;
      }
      // loopのcompletedはonPlayerCompleteで次周を開始する正常な通知である。
      // playingのまま位置が止まった場合だけ、故障としてここへ来る。
      if (mode == _AlertPlaybackMode.loop && !playbackStalled) return;
      emitDiagnostic(
        'audio_playback_stalled',
        {
          'asset': asset,
          'mode': mode.name,
          'playerState': state.value.name,
          'stalledForMs': progressWatchdog.stallThreshold.inMilliseconds,
        },
      );
      recoveryInFlight.value = true;
      final request = requestGeneration.value;
      emitDiagnostic('audio_recovery_started', {
        'asset': asset,
        'mode': mode.name,
        'requestGeneration': request,
        'attempt': consecutiveRecoveryFailures.value + 1,
      });
      final recoveryCommand =
          commandQueue.enqueue(AlertCommandKind.recover, () async {
        try {
          if (initialization.value != null) await initialization.value;
          if (isDisposed.value ||
              request != requestGeneration.value ||
              activeAsset.value != asset) {
            return;
          }
          final target = player.value;
          // PlayerStateはiOSの割込み中にもplayingのまま残る場合がある。
          // 一度pauseしてsessionを非活性化し、mix設定を再適用してから
          // activate/resumeすることで、通話音声との併用中も復帰させる。
          if (playbackStalled) {
            await platformCall('pause', () => target.pause());
          }
          await applyAudioContext(reason: 'stalled_recovery', target: target);
          progressWatchdog.start(DateTime.now());
          // `resume()` だけでは、iOSでcompleted/stoppedになったplayerを
          // 再開できないことがある。sourceは維持したまま先頭へ戻してから
          // 再開し、ループ警告が1周で終わったままにならないようにする。
          await platformCall('seek', () => target.seek(Duration.zero));
          await platformCall('resume', () => target.resume());
          final positionBefore = await platformCall(
            'getCurrentPosition',
            target.getCurrentPosition,
          );
          await Future<void>.delayed(const Duration(milliseconds: 600));
          final positionAfter = await platformCall(
            'getCurrentPosition',
            target.getCurrentPosition,
          );
          if (request != requestGeneration.value ||
              activeAsset.value != asset) {
            if (identical(target, player.value)) {
              await platformCall('stop', target.stop);
            }
            return;
          }
          if (state.value != PlayerState.playing ||
              (positionBefore != null &&
                  positionAfter != null &&
                  positionBefore == positionAfter)) {
            throw StateError('player did not make playback progress');
          }
          consecutiveRecoveryFailures.value = 0;
          emitDiagnostic('audio_recovery_succeeded', {
            'asset': asset,
            'mode': mode.name,
            'positionBeforeMs': positionBefore?.inMilliseconds,
            'positionAfterMs': positionAfter?.inMilliseconds,
          });
        } catch (e) {
          if (isDisposed.value || request != requestGeneration.value) return;
          if (e is TimeoutException &&
              consecutivePlatformTimeouts.value >=
                  alertPlayerRecreateFailureThreshold) {
            try {
              final recreate = recreateAlertPlayer.value;
              if (recreate != null) {
                await recreate(reason: 'recovery_platform_timeout');
                // 新しいplayerにはsourceが無い。元の警告がまだ有効なら、
                // 同じ直列キュー内で完全な再生開始手順をやり直す。
                if (!isDisposed.value &&
                    request == requestGeneration.value &&
                    activeAsset.value == asset &&
                    activeMode.value == mode) {
                  final replay = replayWithFreshPlayer.value;
                  if (replay != null) await replay(asset, mode);
                  // replayは新しいrequestGenerationを発行する。そのままfinallyの
                  // 世代一致判定へ任せると recoveryInFlight がtrueのまま残り、
                  // 次の実際の停止を監視できなくなるため、ここで明示的に解く。
                  recoveryInFlight.value = false;
                  return;
                }
              }
            } catch (_) {
              // 下の既存error/diagnostic経路でaudio_unavailableへ通知する。
            }
          }
          consecutiveRecoveryFailures.value += 1;
          if (consecutiveRecoveryFailures.value >= 3) {
            error.value = '警告音が停止し、自動復旧できません。音量・Bluetooth接続を確認してください。';
          }
          emitDiagnostic('audio_recovery_failed', {
            'asset': asset,
            'mode': mode.name,
            'failureCount': consecutiveRecoveryFailures.value,
            'errorType': e.runtimeType.toString(),
            'errorMessage': errorMessage(e),
          });
          if (kDebugMode) debugPrint('Alert audio recovery error: $e');
        } finally {
          if (request == requestGeneration.value) {
            recoveryInFlight.value = false;
          }
        }
      });
      // recoverが待機中のplay/stopに譲って実行されなかった場合でも、次の
      // watchdog tickを止めない。実行された場合は完了後に同じ値を再設定する。
      unawaited(recoveryCommand.whenComplete(() {
        if (request == requestGeneration.value) {
          recoveryInFlight.value = false;
        }
      }));
    }

    schedulePlaybackWatchdog = (Duration interval) {
      playbackWatchdog?.cancel();
      playbackWatchdog = Timer.periodic(
        interval,
        (_) => runPlaybackWatchdogTick(),
      );
    };
    schedulePlaybackWatchdog(watchdogInterval);
    return () {
      isDisposed.value = true;
      emitDiagnostic('audio_disposed');
      playbackWatchdog?.cancel();
      requestGeneration.value += 1;
      activeAsset.value = null;
      activeMode.value = null;
      activeEventId.value = null;
      playedOnceEventIds.value.clear();
      commandQueue.clear();
      recoveryInFlight.value = false;
      progressWatchdog.reset();
      // 待機中の合図と、完了待ちの待ち手を放置しない。
      cueGeneration.value += 1;
      for (final request in cueQueue.takeAll()) {
        request.complete();
      }
      cueQueue.reset();
      final pendingCueCompletion = cueCompletion.value;
      cueCompletion.value = null;
      if (pendingCueCompletion != null && !pendingCueCompletion.isCompleted) {
        pendingCueCompletion.complete();
      }
      // Hook disposerはFutureを待たないため、世代を先に無効化してから
      // 1本のcleanupに集約する。破棄後はStateを書き換えない。
      unawaited(Future<void>(() async {
        final currentPlayer = player.value;
        try {
          await playerStateSubscription.value?.cancel();
          await playerPositionSubscription.value?.cancel();
          await playerCompleteSubscription.value?.cancel();
          await cueCompleteSubscription.cancel();
          await platformCall('stop', currentPlayer.stop);
          await cuePlayer.stop();
        } finally {
          // 片方の解放が失敗しても、もう片方を必ず解放する。
          try {
            // 破棄自体はOS実装で待ち続ける可能性があるため、Hookのcleanupを
            // ふさがない。以後はisDisposedによりこのplayerへ操作しない。
            unawaited(currentPlayer.dispose());
          } finally {
            await cuePlayer.dispose();
          }
        }
      }).catchError((Object error) {
        if (kDebugMode) debugPrint('Alert audio disposal error: $error');
      }));
    };
  }, []);

  /// 同じアセットの要求が続く間は再スタートせず、そのままループする。
  /// 停止・対象変更と初期化が競合しても古い要求が再生を復活させないよう、
  /// 世代番号で非同期処理を無効化する。
  ///
  /// **直接呼ばないこと。** platform channel を6回awaitするため、複数の要求が
  /// 同時に走ると互いのstop/setSourceに割り込む。必ず [enqueueCommand] 経由で
  /// 1本ずつ実行する。
  Future<void> runPlayWithMode(
    String assetPath,
    _AlertPlaybackMode mode, {
    String? eventId,
  }) async {
    if (isDisposed.value) {
      emitDiagnostic('audio_play_skipped', {'reason': 'disposed'});
      return;
    }
    emitDiagnostic('audio_play_requested', {
      'asset': assetPath,
      'mode': mode.name,
      if (eventId != null) 'eventId': eventId,
      'requestGeneration': requestGeneration.value + 1,
    });
    if (mode == _AlertPlaybackMode.once &&
        eventId != null &&
        playedOnceEventIds.value.contains(eventId)) {
      if (activeEventId.value == eventId &&
          activeMode.value == _AlertPlaybackMode.once) {
        emitDiagnostic('audio_play_skipped', {
          'reason': 'same_once_event_already_active',
          'asset': assetPath,
          'mode': mode.name,
          'eventId': eventId,
        });
        return;
      }
      final request = ++requestGeneration.value;
      activeAsset.value = null;
      activeMode.value = null;
      activeEventId.value = null;
      emitDiagnostic('audio_stop_command', {
        'reason': 'once_event_already_played',
      });
      try {
        await platformCall('stop', player.value.stop);
      } on TimeoutException {
        if (consecutivePlatformTimeouts.value >=
            alertPlayerRecreateFailureThreshold) {
          try {
            await recreateAlertPlayer.value?.call(
              reason: 'once_stop_platform_timeout',
            );
          } catch (_) {
            // 既存のaudio_unavailable表示へ縮退する。
          }
        }
        rethrow;
      }
      if (!isDisposed.value && request == requestGeneration.value) {
        updatePlayerState(
          PlayerState.stopped,
          reason: 'once_event_already_played',
        );
      }
      return;
    }
    if (activeAsset.value == assetPath &&
        activeMode.value == mode &&
        activeEventId.value == eventId &&
        state.value == PlayerState.playing) {
      emitDiagnostic('audio_play_skipped', {
        'reason': 'already_playing_same_target',
        'asset': assetPath,
        'mode': mode.name,
        if (eventId != null) 'eventId': eventId,
      });
      return;
    }
    final request = ++requestGeneration.value;
    try {
      if (initialization.value != null) {
        await initialization.value;
      }
      if (isDisposed.value || request != requestGeneration.value) return;
      final target = player.value;

      // 初期化後に他アプリの音声sessionが変化している可能性があるため、
      // 警告を鳴らす都度contextを再適用する。
      await applyAudioContext(reason: 'play_request', target: target);
      emitDiagnostic('audio_stop_command', {'reason': 'replace_target'});
      await platformCall('stop', target.stop);
      if (isDisposed.value || request != requestGeneration.value) return;
      // loopはonPlayerCompleteでseek(0)+resumeする自前管理だけを使う。
      await platformCall(
        'setReleaseMode',
        () => target.setReleaseMode(ReleaseMode.stop),
      );
      await platformCall('setVolume', () => target.setVolume(1.0));
      await platformCall(
        'setSource',
        () => target.setSource(AssetSource(assetPath)),
      );
      emitDiagnostic('audio_source_set', {
        'asset': assetPath,
        'mode': mode.name,
      });
      if (isDisposed.value || request != requestGeneration.value) return;
      emitDiagnostic('audio_resume_requested', {
        'asset': assetPath,
        'mode': mode.name,
      });
      await platformCall('resume', target.resume);
      if (isDisposed.value || request != requestGeneration.value) {
        if (identical(target, player.value)) {
          await platformCall('stop', target.stop);
        }
        return;
      }
      error.value = null;
      progressWatchdog.start(DateTime.now());
      consecutiveRecoveryFailures.value = 0;
      activeAsset.value = assetPath;
      activeMode.value = mode;
      activeEventId.value = eventId;
      if (mode == _AlertPlaybackMode.once && eventId != null) {
        final played = playedOnceEventIds.value;
        played.add(eventId);
        if (played.length > 256) {
          played.remove(played.first);
        }
      }
      updatePlayerState(PlayerState.playing,
          reason: 'resume_command_completed');
      emitDiagnostic('audio_playback_started', {
        'asset': assetPath,
        'mode': mode.name,
        if (eventId != null) 'eventId': eventId,
        'releaseMode': ReleaseMode.stop.name,
      });
    } catch (e) {
      if (isDisposed.value || request != requestGeneration.value) return;
      if (e is TimeoutException &&
          consecutivePlatformTimeouts.value >=
              alertPlayerRecreateFailureThreshold) {
        try {
          final recreate = recreateAlertPlayer.value;
          if (recreate != null) {
            await recreate(reason: 'play_platform_timeout');
            if (!isDisposed.value) {
              // timeoutしたplayerは破棄済みなので、置き換え先でsource設定から
              // やり直す。ここで再試行しないと、同じdirectiveは依存値が変わらず
              // Hook effectが再実行されないため警告音が無音のまま残る。
              await runPlayWithMode(assetPath, mode, eventId: eventId);
              return;
            }
          }
        } catch (_) {
          // 下の既存error/diagnostic経路でaudio_unavailableへ通知する。
        }
      }
      activeAsset.value = null;
      activeMode.value = null;
      activeEventId.value = null;
      updatePlayerState(PlayerState.stopped, reason: 'playback_error');
      error.value = '警告音を再生できません。端末の音量・消音設定を確認してください。';
      emitDiagnostic('audio_playback_failed', {
        'asset': assetPath,
        'mode': mode.name,
        'errorType': e.runtimeType.toString(),
        'errorMessage': errorMessage(e),
      });
      if (kDebugMode) debugPrint('Alert audio playback error: $e');
    }
  }

  /// 再生・停止要求を1本ずつ実行する。playは最新へ畳むが、stopは必ず残す。
  Future<void> enqueueCommand(
    Future<void> Function() run, {
    required AlertCommandKind kind,
  }) =>
      commandQueue.enqueue(kind, run);

  // Hook effectが動き始める前に参照を設定する。これによりwatchdogが
  // timeout後の置換playerへ、source設定からの再生を委譲できる。
  replayWithFreshPlayer.value = runPlayWithMode;

  Future<void> runLoopRestart({
    required String asset,
    required int request,
  }) async {
    if (isDisposed.value ||
        request != requestGeneration.value ||
        activeAsset.value != asset ||
        activeMode.value != _AlertPlaybackMode.loop) {
      return;
    }
    final target = player.value;
    try {
      await platformCall('seek', () => target.seek(Duration.zero));
      if (isDisposed.value ||
          request != requestGeneration.value ||
          !identical(target, player.value)) {
        return;
      }
      await platformCall('resume', target.resume);
      progressWatchdog.recordLoopRestart(DateTime.now());
      updatePlayerState(PlayerState.playing, reason: 'loop_restart');
      emitDiagnostic('audio_loop_restarted', {
        'asset': asset,
        'mode': _AlertPlaybackMode.loop.name,
        'requestGeneration': request,
      });
    } on TimeoutException {
      if (consecutivePlatformTimeouts.value >=
          alertPlayerRecreateFailureThreshold) {
        try {
          final recreate = recreateAlertPlayer.value;
          if (recreate != null) {
            await recreate(reason: 'loop_restart_platform_timeout');
            if (!isDisposed.value &&
                activeAsset.value == asset &&
                activeMode.value == _AlertPlaybackMode.loop) {
              // 作り直したplayerにはsourceが無い。seek/resumeだけを再試行しても
              // 鳴らないため、source設定から行う通常の開始経路へ戻す。
              await runPlayWithMode(asset, _AlertPlaybackMode.loop);
              return;
            }
          }
        } catch (_) {
          // error値と診断はプレイヤー再作成側が設定する。
        }
      }
      rethrow;
    }
  }

  void scheduleLoopRestart({required String asset, required int request}) {
    if (loopRestartPending.value ||
        isDisposed.value ||
        request != requestGeneration.value ||
        activeAsset.value != asset ||
        activeMode.value != _AlertPlaybackMode.loop) {
      return;
    }
    loopRestartPending.value = true;
    final restart = enqueueCommand(
      () => runLoopRestart(asset: asset, request: request),
      kind: AlertCommandKind.recover,
    );
    unawaited(restart.whenComplete(() => loopRestartPending.value = false));
  }

  // 購読はHook effectの中で作るため、ここで最新の再始動関数を渡す。
  requestLoopRestart.value = scheduleLoopRestart;

  Future<void> play(String assetPath) => enqueueCommand(
        () => runPlayWithMode(assetPath, _AlertPlaybackMode.loop),
        kind: AlertCommandKind.play,
      );

  Future<void> playOnce(String assetPath, {String? eventId}) => enqueueCommand(
        () => runPlayWithMode(
          assetPath,
          _AlertPlaybackMode.once,
          eventId: eventId,
        ),
        kind: AlertCommandKind.play,
      );

  /// 単発合図を1件だけ再生する。**cue専用プレイヤーだけ**を触る。
  ///
  /// **直接呼ばないこと。** 必ず [drainCueQueue] 経由で1件ずつ実行する。
  Future<void> runCue(AlertCueRequest request) async {
    final generation = cueGeneration.value;
    if (isDisposed.value) {
      emitDiagnostic('audio_cue_skipped', {
        'asset': request.assetPath,
        'eventId': request.eventId,
        'reason': 'disposed',
      });
      return;
    }
    try {
      if (cueInitialization.value != null) await cueInitialization.value;
      if (isDisposed.value || generation != cueGeneration.value) {
        emitDiagnostic('audio_cue_skipped', {
          'asset': request.assetPath,
          'eventId': request.eventId,
          'reason': isDisposed.value ? 'disposed' : 'superseded',
        });
        return;
      }
      // 前の合図が残っていれば止める。止めるのはcueプレイヤーだけで、
      // 持続音のプレイヤーには触れない。
      await cuePlayer.stop();
      await cuePlayer.setReleaseMode(ReleaseMode.stop);
      await cuePlayer.setVolume(1.0);
      await cuePlayer.setSource(AssetSource(request.assetPath));
      if (isDisposed.value || generation != cueGeneration.value) {
        emitDiagnostic('audio_cue_skipped', {
          'asset': request.assetPath,
          'eventId': request.eventId,
          'reason': isDisposed.value ? 'disposed' : 'superseded',
        });
        return;
      }
      final completion = Completer<void>();
      cueCompletion.value = completion;
      await cuePlayer.resume();
      emitDiagnostic('audio_cue_started', {
        'asset': request.assetPath,
        'eventId': request.eventId,
      });
      // 鳴り終わるまで次の合図を始めない。同時に鳴らすと、後の合図が
      // 前の合図を途中で打ち消す。
      await completion.future.timeout(_cuePlaybackTimeout, onTimeout: () {
        emitDiagnostic('audio_cue_failed', {
          'asset': request.assetPath,
          'eventId': request.eventId,
          'reason': 'completion_timeout',
        });
      });
      if (identical(cueCompletion.value, completion)) {
        cueCompletion.value = null;
      }
    } catch (e) {
      // cueの失敗は error.value を汚さない(要件5)。診断とログにだけ残す。
      emitDiagnostic('audio_cue_failed', {
        'asset': request.assetPath,
        'eventId': request.eventId,
        'reason': 'playback_failed',
        'errorType': e.runtimeType.toString(),
        'errorMessage': errorMessage(e),
      });
      if (kDebugMode) debugPrint('Alert cue playback error: $e');
    }
  }

  /// 待機中の合図をFIFOで順に鳴らす。
  Future<void> drainCueQueue() async {
    if (cueDraining.value) return;
    cueDraining.value = true;
    try {
      while (true) {
        final next = cueQueue.takeNext();
        if (next == null) break;
        try {
          await runCue(next);
        } finally {
          next.complete();
        }
      }
    } finally {
      cueDraining.value = false;
    }
  }

  /// 単発合図を確実に黙らせる。停止・破棄から呼ぶ。
  Future<void> stopCue({required String reason}) async {
    cueGeneration.value += 1;
    for (final request in cueQueue.takeAll()) {
      emitDiagnostic('audio_cue_dropped', {
        'asset': request.assetPath,
        'eventId': request.eventId,
        'reason': reason,
      });
      request.complete();
    }
    // 再生完了待ちを解いて、実行中のrunCueを世代チェックで抜けさせる。
    final completion = cueCompletion.value;
    cueCompletion.value = null;
    if (completion != null && !completion.isCompleted) completion.complete();
    if (isDisposed.value) return;
    try {
      await cuePlayer.stop();
    } catch (e) {
      emitDiagnostic('audio_cue_failed', {
        'reason': 'stop_failed',
        'errorType': e.runtimeType.toString(),
        'errorMessage': errorMessage(e),
      });
      if (kDebugMode) debugPrint('Alert cue stop error: $e');
    }
  }

  /// 単発合図を鳴らす。持続する警告音とは独立したチャンネルで再生するため、
  /// 連続音が鳴っている間でも確実に届く。
  ///
  /// [eventId] は重複排除キー。同じ eventId は二度鳴らさない。
  Future<void> playCue(String assetPath, {required String eventId}) {
    emitDiagnostic('audio_cue_requested', {
      'asset': assetPath,
      'eventId': eventId,
    });
    if (isDisposed.value) {
      emitDiagnostic('audio_cue_skipped', {
        'asset': assetPath,
        'eventId': eventId,
        'reason': 'disposed',
      });
      return Future<void>.value();
    }
    final request = AlertCueRequest(assetPath, eventId);
    final admission = cueQueue.admit(request);
    for (final dropped in admission.dropped) {
      emitDiagnostic('audio_cue_dropped', {
        'asset': dropped.assetPath,
        'eventId': dropped.eventId,
        'reason': 'queue_overflow',
      });
      dropped.complete();
    }
    if (!admission.accepted) {
      emitDiagnostic('audio_cue_skipped', {
        'asset': assetPath,
        'eventId': eventId,
        'reason': admission.rejectReason,
      });
      return Future<void>.value();
    }
    unawaited(drainCueQueue());
    return request.done;
  }

  Future<void> runStop() async {
    final hadPlayback = activeAsset.value != null ||
        state.value == PlayerState.playing ||
        state.value == PlayerState.paused;
    if (hadPlayback) {
      emitDiagnostic('audio_stop_requested', {
        'asset': activeAsset.value,
        'mode': activeMode.value?.name,
        'eventId': activeEventId.value,
      });
    }
    final request = ++requestGeneration.value;
    activeAsset.value = null;
    activeMode.value = null;
    activeEventId.value = null;
    consecutiveRecoveryFailures.value = 0;
    recoveryInFlight.value = false;
    progressWatchdog.reset();
    // 単発合図も一緒に黙らせる。航行終了後に遅れて鳴らせない。
    await stopCue(reason: 'stop_requested');
    if (isDisposed.value) {
      if (hadPlayback) {
        emitDiagnostic('audio_stop_completed', {'disposed': true});
      }
      return;
    }
    emitDiagnostic('audio_stop_command', {'reason': 'navigation_or_directive'});
    try {
      await platformCall('stop', player.value.stop);
    } on TimeoutException {
      if (consecutivePlatformTimeouts.value >=
          alertPlayerRecreateFailureThreshold) {
        try {
          await recreateAlertPlayer.value?.call(
            reason: 'stop_platform_timeout',
          );
        } catch (_) {
          // 既存のaudio_unavailable表示へ縮退する。
        }
      }
      rethrow;
    }
    if (!isDisposed.value && request == requestGeneration.value) {
      updatePlayerState(PlayerState.stopped, reason: 'stop_command_completed');
    }
    if (hadPlayback) emitDiagnostic('audio_stop_completed');
  }

  Future<void> stop() => enqueueCommand(runStop, kind: AlertCommandKind.stop);

  /// 音を鳴らさず、警告音の設定・アセット準備だけを確認する。
  Future<bool> checkReady() async {
    emitDiagnostic('audio_readiness_check_started');
    try {
      if (initialization.value != null) {
        await initialization.value;
      }
      final ready = error.value == null;
      emitDiagnostic('audio_readiness_check_finished', {'ready': ready});
      return ready;
    } catch (e) {
      error.value = '警告音の準備に失敗しました。端末の音声設定を確認してください。';
      if (kDebugMode) debugPrint('Alert audio readiness check error: $e');
      emitDiagnostic('audio_readiness_check_failed', {
        'errorType': e.runtimeType.toString(),
        'errorMessage': errorMessage(e),
      });
      return false;
    }
  }

  /// 航行開始前に短い警告音を再生し、端末から音が出せる状態か確認する。
  Future<bool> test() async {
    emitDiagnostic('audio_test_started', {'asset': genericWarningAudioAsset});
    await play(genericWarningAudioAsset);
    if (error.value != null) {
      emitDiagnostic('audio_test_finished', {
        'success': false,
        'reason': 'playback_error',
      });
      return false;
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await stop();
    final success = error.value == null;
    emitDiagnostic('audio_test_finished', {'success': success});
    return success;
  }

  Future<void> dispose() async {
    emitDiagnostic('audio_dispose_requested');
    // 待機中の要求は捨てる。破棄後にplayerへ触らせない。
    commandQueue.clear();
    requestGeneration.value += 1;
    activeAsset.value = null;
    activeMode.value = null;
    activeEventId.value = null;
    playedOnceEventIds.value.clear();
    progressWatchdog.reset();
    await stopCue(reason: 'disposed');
    cueQueue.reset();
    if (isDisposed.value) return;
    isDisposed.value = true;
    // 片方の解放が失敗しても、もう片方を必ず解放する。
    try {
      await player.value.dispose();
    } finally {
      await cuePlayer.dispose();
    }
  }

  return UseAlert(
    isPlaying: state.value == PlayerState.playing,
    error: error,
    play: play,
    playOnce: playOnce,
    playCue: playCue,
    checkReady: checkReady,
    test: test,
    stop: stop,
    dispose: dispose,
  );
}

class UseAlert {
  final bool isPlaying;
  final ValueNotifier<String?> error;
  final Future<void> Function(String assetPath) play;
  final Future<void> Function(String assetPath, {String? eventId}) playOnce;

  /// 単発合図を鳴らす。持続する警告音とは独立したチャンネルで再生するため、
  /// 連続音が鳴っている間でも確実に届く。
  ///
  /// [eventId] は重複排除キー。同じ eventId は二度鳴らさない。
  final Future<void> Function(String assetPath, {required String eventId})
      playCue;
  final Future<bool> Function() checkReady;
  final Future<bool> Function() test;
  final Future<void> Function() stop;
  final Future<void> Function() dispose;

  UseAlert({
    required this.isPlaying,
    required this.error,
    required this.play,
    required this.playOnce,
    required this.playCue,
    required this.checkReady,
    required this.test,
    required this.stop,
    required this.dispose,
  });
}
