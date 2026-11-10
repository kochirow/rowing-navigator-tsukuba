import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/log_upload_config.dart';
import '../models/message_model.dart';
import '../models/practice_log_model.dart';
import '../models/session_model.dart';
import 'diagnostic_bundle_service.dart';
import 'practice_log_export_service.dart';
import 'practice_log_store_service.dart';
import 'session_store_service.dart';

// # 練習ログの自動回収
//
// 航行・監視を終えたら、その記録の診断ZIP(「まとめて送る」と同じ中身)を
// Google Apps Script の受け口へ送り、開発者の Google ドライブに保存する。
//
// - 送る対象: 記録が完了していて、長さが [autoLogUploadMinDurationSec] 以上。
// - 送れたら、その記録に「送信済み」の印(diagnosticsSharedAt)を付ける。
//   「まとめて送る」の未送信の件数からも外れる。
// - 送れなかった記録は端末内の送信待ちの列に残し、少し待って・アプリを前面に
//   戻したとき・次の起動で送り直す。
// - 「今日の記録」シートで評価やひとことを書いたら、もう一度送る。
//   受け口は同じ記録のファイルを置き換える。送っている最中に依頼が来たら、
//   送り終えた後にもう一度送る(古い版だけが届いて終わらないように)。
// - 監視ログは、記録したチームといま入っているチームが同じときだけ送る
//   (他艇の航跡と名前が入るので、前に入っていたチームの記録を今のチームへ出さない)。
// - 安全経路(判定・警告・位置共有)は何も参照しない。送信の失敗で
//   地図や次の航行を止めない。

/// 送信待ちの列の1件。練習記録か監視ログか。
@immutable
class AutoLogUploadTarget {
  final String id;
  final bool isPracticeLog;

  const AutoLogUploadTarget.session(this.id) : isPracticeLog = false;
  const AutoLogUploadTarget.practiceLog(this.id) : isPracticeLog = true;

  /// 端末内に保存する形(`s:<id>` / `p:<id>`)。
  String get key => '${isPracticeLog ? 'p' : 's'}:$id';

  static AutoLogUploadTarget? fromKey(String key) {
    if (key.length < 3 || key[1] != ':') return null;
    final id = key.substring(2);
    return switch (key[0]) {
      's' => AutoLogUploadTarget.session(id),
      'p' => AutoLogUploadTarget.practiceLog(id),
      _ => null,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is AutoLogUploadTarget &&
      other.id == id &&
      other.isPracticeLog == isPracticeLog;

  @override
  int get hashCode => Object.hash(id, isPracticeLog);

  @override
  String toString() => key;
}

/// 受け口の返事。
class LogUploadResponse {
  final bool ok;

  /// 失敗の理由(受け口が返した `error`、または通信の失敗)。
  final String? error;

  const LogUploadResponse.success()
      : ok = true,
        error = null;
  const LogUploadResponse.failure(this.error) : ok = false;

  /// 受け口の本文(JSON)を読む。JSON でない本文(ログイン画面など)は失敗。
  static LogUploadResponse parse(int statusCode, String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['ok'] == true) {
        return const LogUploadResponse.success();
      }
      if (decoded is Map && decoded['error'] is String) {
        return LogUploadResponse.failure(decoded['error'] as String);
      }
    } catch (_) {
      // 下で HTTP の状態と一緒に返す。
    }
    return LogUploadResponse.failure('unexpected_response_$statusCode');
  }
}

typedef LogUploadPoster = Future<LogUploadResponse> Function(
    Uri endpoint, Map<String, Object?> body);
typedef LogUploadTokenProvider = Future<String?> Function();
typedef SessionBundleBuilder = Future<List<DiagnosticBundle>> Function(
    List<Session> sessions, List<PracticeLogBundleInput> practiceLogs);

/// 1件を送った結果。
enum AutoLogUploadOutcome {
  /// 送れた。列から外し、送信済みの印を付けた。
  uploaded,

  /// 送る対象ではない(記録が無い・短い・未完了)。列から外した。
  skipped,

  /// 送れなかった。列に残した。
  failed,
}

/// 長さが下限以上の、完了した練習記録か。
bool isAutoLogUploadSession(Session s,
        {double minDurationSec = autoLogUploadMinDurationSec}) =>
    s.isComplete && sessionDurationSecOf(s) >= minDurationSec;

/// 記録の長さ [秒]。集計が無い古い記録は始まりと終わりの差で数える。
double sessionDurationSecOf(Session s) => s.summary.durationSec > 0
    ? s.summary.durationSec
    : s.endedAt.difference(s.startedAt).inMilliseconds / 1000;

/// 長さが下限以上の、完了した監視ログか。
bool isAutoLogUploadPracticeLog(PracticeLog log,
        {double minDurationSec = autoLogUploadMinDurationSec}) =>
    log.isComplete && practiceLogSecOf(log) >= minDurationSec;

/// 起動時に拾う、まだ送っていない練習記録(別 isolate で判定するため top-level)。
bool isPendingAutoLogUploadSession(Session s) =>
    !s.isDiagnosticsShared && isAutoLogUploadSession(s);

class AutoLogUploadService {
  /// 送信待ちの列を保存するキー。アカウントとデータの削除で一緒に消える
  /// (AccountDataDeletionService は SharedPreferences を全消去する)。
  static const queueKey = 'auto_log_upload_queue_v1';

  final String endpoint;
  final double minDurationSec;
  final SessionStoreService _sessions;
  final PracticeLogStoreService _practiceLogs;
  final PracticeLogExportService _practiceExport;
  final LogUploadPoster _post;
  final LogUploadTokenProvider _idToken;
  final LogUploadTokenProvider _appCheckToken;
  final LogUploadTokenProvider _displayName;
  final LogUploadTokenProvider _currentTeamId;
  final SessionBundleBuilder _buildBundles;
  final Future<SharedPreferences> Function() _prefs;
  final DateTime Function() _now;
  final List<Duration> retryDelays;

  AutoLogUploadService({
    String? endpoint,
    this.minDurationSec = autoLogUploadMinDurationSec,
    SessionStoreService? sessionStore,
    PracticeLogStoreService? practiceLogStore,
    PracticeLogExportService? practiceLogExport,
    LogUploadPoster? poster,
    LogUploadTokenProvider? idToken,
    LogUploadTokenProvider? appCheckToken,
    LogUploadTokenProvider? displayName,
    LogUploadTokenProvider? currentTeamId,
    SessionBundleBuilder? buildBundles,
    Future<SharedPreferences> Function()? prefs,
    DateTime Function()? now,
    this.retryDelays = autoLogUploadRetryDelays,
  })  : endpoint = endpoint ?? autoLogUploadEndpoint,
        _sessions = sessionStore ?? SessionStoreService(),
        _practiceLogs = practiceLogStore ?? PracticeLogStoreService(),
        _practiceExport = practiceLogExport ?? PracticeLogExportService(),
        _post = poster ?? postLogUpload,
        _idToken = idToken ?? (() async => null),
        _appCheckToken = appCheckToken ?? (() async => null),
        _displayName = displayName ?? (() async => null),
        _currentTeamId = currentTeamId ?? (() async => null),
        _buildBundles = buildBundles ??
            ((sessions, practiceLogs) => DiagnosticBundleService()
                .buildBundlesInBackground(sessions,
                    practiceLogs: practiceLogs, automaticUpload: true)),
        _prefs = prefs ?? SharedPreferences.getInstance,
        _now = now ?? DateTime.now;

  bool get enabled => endpoint.trim().isNotEmpty;

  final List<StreamSubscription<String>> _subscriptions = [];
  AppLifecycleListener? _lifecycle;
  Timer? _retryTimer;
  int _retryAttempt = 0;
  Future<void>? _draining;
  bool _drainAgain = false;
  bool _started = false;

  /// 列の読み書きを1本ずつ順に行うための鎖。読んでから書くまでの間に
  /// 別の追加が割り込むと、片方の追加が消えるため。
  Future<void> _queueLock = Future.value();

  /// いま送っている記録。
  AutoLogUploadTarget? _inFlight;

  /// 送っている最中に送り直しを頼まれた記録。送り終えても列から外さず、もう一度送る。
  final Set<AutoLogUploadTarget> _resendAfterInFlight = {};

  /// 航行・監視の終わりを待ち受け、まだ送っていない記録を拾って送る。
  /// 何度呼んでも1回だけ動く。受け口が未設定なら何もしない。
  void start({Duration backlogDelay = const Duration(seconds: 10)}) {
    if (_started || !enabled) return;
    _started = true;
    _subscriptions
      ..add(SessionStoreService.finishedSessionIds
          .listen((id) => unawaited(enqueue(AutoLogUploadTarget.session(id)))))
      ..add(PracticeLogStoreService.finishedLogIds.listen(
          (id) => unawaited(enqueue(AutoLogUploadTarget.practiceLog(id)))));
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(drain()));
    // 起動の処理と取り合わないよう、少し待ってから拾う。
    Timer(backlogDelay, () => unawaited(enqueueBacklog()));
  }

  void dispose() {
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    _subscriptions.clear();
    _lifecycle?.dispose();
    _lifecycle = null;
    _retryTimer?.cancel();
    _started = false;
  }

  /// 「今日の記録」シートで評価・ひとことを書いた後に、もう一度送る。
  /// [start] していないとき(テスト・受け口が未設定)は何もしない。
  Future<void> requestReupload(AutoLogUploadTarget target) async {
    if (!_started) return;
    await enqueue(target);
  }

  /// 列に足して、すぐ送る。同じ記録が列にあれば足さない。
  /// 列にある記録は、送信済みの印があっても送る(評価を書いた後の送り直し)。
  Future<void> enqueue(AutoLogUploadTarget target) async {
    if (!enabled) return;
    try {
      await _withQueue((queue) {
        if (target == _inFlight) _resendAfterInFlight.add(target);
        return queue.contains(target) ? null : [...queue, target];
      });
    } catch (error) {
      debugPrint('自動回収の列に足せませんでした: $error');
      return;
    }
    await drain();
  }

  /// まだ送っていない記録(送信済みの印が無く、下限以上)を列に足して送る。
  /// この版を入れる前の記録も、ここで一度だけ拾われる。
  Future<void> enqueueBacklog() async {
    if (!enabled) return;
    final found = <AutoLogUploadTarget>[];
    try {
      final ids = minDurationSec == autoLogUploadMinDurationSec
          ? await _sessions.idsMatching(isPendingAutoLogUploadSession)
          : [
              for (final s in await _sessions.listSessions())
                if (!s.isDiagnosticsShared &&
                    isAutoLogUploadSession(s, minDurationSec: minDurationSec))
                  s.id
            ];
      found.addAll(ids.map(AutoLogUploadTarget.session));
    } catch (error) {
      debugPrint('自動回収: 練習記録を読めませんでした: $error');
    }
    try {
      // チームが分からないうちは監視ログを拾わない(次の起動で拾う)。
      final teamId = await _currentTeamIdOrNull();
      for (final log in await _practiceLogs.list()) {
        if (teamId != null &&
            log.teamId == teamId &&
            !log.isDiagnosticsShared &&
            isAutoLogUploadPracticeLog(log, minDurationSec: minDurationSec)) {
          found.add(AutoLogUploadTarget.practiceLog(log.id));
        }
      }
    } catch (error) {
      debugPrint('自動回収: 監視ログを読めませんでした: $error');
    }
    try {
      await _withQueue((queue) {
        final added = [
          for (final t in found)
            if (!queue.contains(t)) t
        ];
        return added.isEmpty ? null : [...queue, ...added];
      });
    } catch (error) {
      debugPrint('自動回収の列に足せませんでした: $error');
      return;
    }
    await drain();
  }

  /// 列の記録を古い順に送る。送っている途中に呼ばれたら、終わってからもう一度回す。
  Future<void> drain() {
    if (!enabled) return Future.value();
    final running = _draining;
    if (running != null) {
      _drainAgain = true;
      return running;
    }
    final future = _drainLoop().whenComplete(() => _draining = null);
    _draining = future;
    return future;
  }

  Future<void> _drainLoop() async {
    do {
      _drainAgain = false;
      final queue = await _readQueueOrEmpty();
      var failed = false;
      for (final target in queue) {
        _inFlight = target;
        final AutoLogUploadOutcome outcome;
        try {
          outcome = await uploadOne(target);
        } finally {
          _inFlight = null;
        }
        if (outcome == AutoLogUploadOutcome.failed) {
          // 圏外のときは残りも送れないので、ここで止めて待つ。
          // 失敗した記録は列の最後へ回し、1件の不具合で他の記録が止まらないようにする。
          _resendAfterInFlight.remove(target);
          await _moveToEnd(target);
          failed = true;
          break;
        }
        if (_resendAfterInFlight.remove(target)) {
          // 送っている間に内容が変わった。列に残し、この後もう一度送る。
          _drainAgain = true;
          continue;
        }
        await _remove(target);
      }
      if (failed) {
        _scheduleRetry();
        return;
      }
      _retryAttempt = 0;
      _retryTimer?.cancel();
    } while (_drainAgain);
  }

  void _scheduleRetry() {
    if (retryDelays.isEmpty || _retryTimer?.isActive == true) return;
    final index = _retryAttempt.clamp(0, retryDelays.length - 1);
    _retryAttempt++;
    _retryTimer = Timer(retryDelays[index], () => unawaited(drain()));
  }

  /// 1件を送る(テスト用に公開)。列の出し入れはしない。
  @visibleForTesting
  Future<AutoLogUploadOutcome> uploadOne(AutoLogUploadTarget target) async {
    try {
      final prepared = target.isPracticeLog
          ? await _preparePracticeLog(target.id)
          : await _prepareSession(target.id);
      if (prepared == null) return AutoLogUploadOutcome.skipped;

      final idToken = await _idToken();
      if (idToken == null || idToken.isEmpty) {
        // チームに入る前・ログインが切れたとき。入った後に送る。
        return AutoLogUploadOutcome.failed;
      }
      String? appCheckToken;
      try {
        appCheckToken = await _appCheckToken();
      } catch (_) {
        // 受け口が要らない設定なら無くても通る。要る設定なら受け口が断る。
      }
      String? displayName;
      try {
        displayName = await _displayName();
      } catch (_) {}

      final response = await _post(Uri.parse(endpoint.trim()), {
        'v': 1,
        'idToken': idToken,
        if (appCheckToken != null && appCheckToken.isNotEmpty)
          'appCheckToken': appCheckToken,
        'kind': target.isPracticeLog ? 'practiceLog' : 'session',
        'recordId': target.id,
        'startedAt': prepared.startedAt.toUtc().toIso8601String(),
        'durationSec': prepared.durationSec.round(),
        'displayName': displayName,
        'boatType': prepared.boatType,
        if (prepared.recordTeamId != null)
          'recordTeamId': prepared.recordTeamId,
        'appVersion': Message.currentAppVersion,
        'platform': Platform.operatingSystem,
        'fileName': prepared.bundle.fileName,
        'zipBase64': base64Encode(prepared.bundle.bytes),
      });
      if (!response.ok && response.error == 'team_mismatch') {
        // 受け口が「記録したチームが今のチームと違う」と断った。送り直しても通らない。
        debugPrint('自動回収: ${target.key} は今のチームの記録ではないので送りません');
        return AutoLogUploadOutcome.skipped;
      }
      if (!response.ok) {
        debugPrint('自動回収: ${target.key} を送れませんでした: ${response.error}');
        return AutoLogUploadOutcome.failed;
      }
      await _markUploaded(target);
      return AutoLogUploadOutcome.uploaded;
    } catch (error) {
      debugPrint('自動回収: ${target.key} を送れませんでした: $error');
      return AutoLogUploadOutcome.failed;
    }
  }

  Future<_PreparedUpload?> _prepareSession(String id) async {
    final session = await _sessions.loadSession(id);
    if (session == null ||
        !isAutoLogUploadSession(session, minDurationSec: minDurationSec)) {
      return null;
    }
    final bundles = await _buildBundles([session], const []);
    if (bundles.isEmpty) return null;
    return _PreparedUpload(
      bundle: bundles.first,
      startedAt: session.startedAt,
      durationSec: sessionDurationSecOf(session),
      boatType: session.boatTypeName,
    );
  }

  Future<_PreparedUpload?> _preparePracticeLog(String id) async {
    final ({
      PracticeLog log,
      List<PracticeLogPoint> points,
      List<PracticeLogEvent> events
    }) data;
    try {
      data = await _practiceLogs.read(id);
    } on FileSystemException {
      return null; // 消された監視ログ
    } on ArgumentError {
      return null; // 監視ログのIDの形ではない
    }
    final meta = data.log;
    if (!isAutoLogUploadPracticeLog(meta, minDurationSec: minDurationSec)) {
      return null;
    }
    final teamId = await _currentTeamIdOrNull();
    if (teamId == null) {
      throw const _NotReady('チームが分かりません');
    }
    if (meta.teamId != teamId) return null; // 前に入っていたチームの記録
    final bundles = await _buildBundles(const [], [
      PracticeLogBundleInput(
          log: meta,
          files: _practiceExport.buildFiles(meta, data.points, data.events)),
    ]);
    if (bundles.isEmpty) return null;
    return _PreparedUpload(
      bundle: bundles.first,
      startedAt: meta.startedAt,
      durationSec: practiceLogSecOf(meta),
      boatType: null,
      recordTeamId: meta.teamId,
    );
  }

  /// 送信済みの印を付ける。もう付いていれば、最初に送った時刻を残す。
  Future<void> _markUploaded(AutoLogUploadTarget target) async {
    final now = _now();
    try {
      if (target.isPracticeLog) {
        final logs = await _practiceLogs.list();
        final log = logs.where((l) => l.id == target.id).firstOrNull;
        if (log != null && !log.isDiagnosticsShared) {
          await _practiceLogs.markDiagnosticsShared(target.id, now);
        }
      } else {
        final session = await _sessions.loadSession(target.id);
        if (session != null && !session.isDiagnosticsShared) {
          await _sessions
              .saveSession(session.copyWith(diagnosticsSharedAt: () => now));
        }
      }
    } catch (error) {
      // 印が付かなくても、ドライブには届いている。次の起動で同じ記録を送り直し、
      // 受け口が置き換える。
      debugPrint('自動回収: ${target.key} に送信済みの印を付けられませんでした: $error');
    }
  }

  /// いまの送信待ちの列(テスト・表示用)。
  Future<List<AutoLogUploadTarget>> pending() => _readQueueOrEmpty();

  Future<List<AutoLogUploadTarget>> _readQueue() async {
    final prefs = await _prefs();
    return [
      for (final key in prefs.getStringList(queueKey) ?? const <String>[])
        if (AutoLogUploadTarget.fromKey(key) case final target?) target
    ];
  }

  Future<List<AutoLogUploadTarget>> _readQueueOrEmpty() async {
    try {
      return await _readQueue();
    } catch (error) {
      debugPrint('自動回収の列を読めませんでした: $error');
      return const [];
    }
  }

  Future<void> _writeQueue(List<AutoLogUploadTarget> queue) async {
    final prefs = await _prefs();
    await prefs.setStringList(queueKey, [for (final t in queue) t.key]);
  }

  /// 列を読み、[change] の結果で書き換える(null なら書かない)。
  /// 読んでから書くまでを他の書き換えと重ねない。
  Future<void> _withQueue(
      List<AutoLogUploadTarget>? Function(List<AutoLogUploadTarget> queue)
          change) {
    final run = _queueLock.then((_) async {
      final next = change(await _readQueue());
      if (next != null) await _writeQueue(next);
    });
    // 失敗しても鎖は切らない(次の書き換えは動かす)。失敗は呼び出し側へ返す。
    _queueLock = run.catchError((_) {});
    return run;
  }

  Future<void> _remove(AutoLogUploadTarget target) async {
    try {
      await _withQueue((queue) => [
            for (final t in queue)
              if (t != target) t
          ]);
    } catch (error) {
      debugPrint('自動回収の列を更新できませんでした: $error');
    }
  }

  Future<void> _moveToEnd(AutoLogUploadTarget target) async {
    try {
      await _withQueue((queue) => !queue.contains(target)
          ? null
          : [
              for (final t in queue)
                if (t != target) t,
              target,
            ]);
    } catch (error) {
      debugPrint('自動回収の列を更新できませんでした: $error');
    }
  }

  Future<String?> _currentTeamIdOrNull() async {
    try {
      final id = await _currentTeamId();
      return id == null || id.isEmpty ? null : id;
    } catch (_) {
      return null;
    }
  }
}

class _PreparedUpload {
  final DiagnosticBundle bundle;
  final DateTime startedAt;
  final double durationSec;
  final String? boatType;

  /// 記録したチーム。監視ログだけ(練習記録はチームを持たない)。
  final String? recordTeamId;

  const _PreparedUpload({
    required this.bundle,
    required this.startedAt,
    required this.durationSec,
    required this.boatType,
    this.recordTeamId,
  });
}

/// まだ送れない(チームが分からない等)。列に残して後で送る。
class _NotReady implements Exception {
  final String reason;
  const _NotReady(this.reason);
  @override
  String toString() => reason;
}

/// 受け口へ JSON を POST する。
///
/// Apps Script のウェブアプリは、POST を処理したあと結果を別の URL へ
/// 302 で案内する。dart:io は POST の 302 をたどらないので、案内先を GET で読む。
Future<LogUploadResponse> postLogUpload(
  Uri endpoint,
  Map<String, Object?> body, {
  Duration timeout = autoLogUploadRequestTimeout,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final request = await client.postUrl(endpoint).timeout(timeout);
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.add(utf8.encode(jsonEncode(body)));
    var response = await request.close().timeout(timeout);
    var status = response.statusCode;
    var text = await response.transform(utf8.decoder).join().timeout(timeout);
    final location = response.headers.value(HttpHeaders.locationHeader);
    if (status >= 300 && status < 400 && location != null) {
      final follow =
          await client.getUrl(endpoint.resolve(location)).timeout(timeout);
      response = await follow.close().timeout(timeout);
      status = response.statusCode;
      text = await response.transform(utf8.decoder).join().timeout(timeout);
    }
    return LogUploadResponse.parse(status, text);
  } on TimeoutException {
    return const LogUploadResponse.failure('timeout');
  } on IOException catch (error) {
    return LogUploadResponse.failure('network: $error');
  } finally {
    client.close(force: true);
  }
}
