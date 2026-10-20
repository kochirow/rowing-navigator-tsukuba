import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// どこにも捕まえられなかった例外の1件。
///
/// 端末内の診断ログにだけ残す(サーバーへは送らない)。
/// 例外の文面に利用者の入力が混ざりうるので、長さを切り詰める。
class UncaughtErrorRecord {
  static const maxMessageLength = 300;
  static const maxStackLines = 8;
  static const maxStackLength = 1200;

  final DateTime at;

  /// `flutter`(フレームワーク内)/ `platform`(非同期の未処理)のどちらか。
  final String source;
  final String errorType;
  final String message;
  final String? stackTop;

  /// 前回の起動で記録され、今回の起動で読み出したもの。
  final bool previousRun;

  /// この記録の前に、同じ例外を記録せずに数えた回数
  /// ([UncaughtErrorJournal.repeatWindow] の間引き)。
  final int suppressedRepeats;

  const UncaughtErrorRecord({
    required this.at,
    required this.source,
    required this.errorType,
    required this.message,
    this.stackTop,
    this.previousRun = false,
    this.suppressedRepeats = 0,
  });

  factory UncaughtErrorRecord.capture(
    Object error,
    StackTrace? stackTrace, {
    required String source,
    DateTime? at,
  }) {
    return UncaughtErrorRecord(
      at: at ?? DateTime.now(),
      source: source,
      errorType: error.runtimeType.toString(),
      message: _truncate(error.toString(), maxMessageLength),
      stackTop: stackTrace == null ? null : _stackTop(stackTrace),
    );
  }

  UncaughtErrorRecord asPreviousRun() => UncaughtErrorRecord(
        at: at,
        source: source,
        errorType: errorType,
        message: message,
        stackTop: stackTop,
        previousRun: true,
        suppressedRepeats: suppressedRepeats,
      );

  UncaughtErrorRecord withSuppressedRepeats(int count) => UncaughtErrorRecord(
        at: at,
        source: source,
        errorType: errorType,
        message: message,
        stackTop: stackTop,
        previousRun: previousRun,
        suppressedRepeats: count,
      );

  /// 同じ例外かどうかを見分けるキー(発生元・型・文面)。
  String get repeatKey => '$source|$errorType|$message';

  Map<String, dynamic> toJson() => {
        'at': at.toUtc().toIso8601String(),
        'source': source,
        'errorType': errorType,
        'message': message,
        if (stackTop != null) 'stackTop': stackTop,
        if (suppressedRepeats > 0) 'suppressedRepeats': suppressedRepeats,
      };

  Map<String, dynamic> toDiagnosticDetails() => {
        ...toJson(),
        'previousRun': previousRun,
      };

  static UncaughtErrorRecord? tryParse(String line) {
    try {
      final json = jsonDecode(line);
      if (json is! Map<String, dynamic>) return null;
      final at = DateTime.tryParse(json['at'] as String? ?? '');
      final source = json['source'];
      final errorType = json['errorType'];
      final message = json['message'];
      if (at == null ||
          source is! String ||
          errorType is! String ||
          message is! String) {
        return null;
      }
      final stackTop = json['stackTop'];
      final suppressed = json['suppressedRepeats'];
      return UncaughtErrorRecord(
        at: at,
        source: source,
        errorType: errorType,
        message: message,
        stackTop: stackTop is String ? stackTop : null,
        suppressedRepeats: suppressed is int && suppressed > 0 ? suppressed : 0,
      );
    } catch (_) {
      return null;
    }
  }

  static String _truncate(String value, int limit) =>
      value.length <= limit ? value : '${value.substring(0, limit)}…';

  static String _stackTop(StackTrace stackTrace) {
    final lines = stackTrace
        .toString()
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .take(maxStackLines)
        .join('\n');
    return _truncate(lines, maxStackLength);
  }
}

/// 捕まえていない例外を、航行中の診断ログと次回起動へ渡す。
///
/// 漕手は航行中に端末を触れないので、バックグラウンドで例外が起きても
/// 誰も気づけず、原因も残らなかった(2026-10-20 のレビューで判明)。
/// ここで受けた例外は次の2か所へ流れる。
///
/// - 航行中: `use_navigator` が [drainUnreported] で受け取り、
///   診断ログ(events.jsonl)へ `uncaught_error` として書く。
/// - 航行していない間・落ちる直前: 端末内のファイルへ追記しておき、
///   次回起動後の最初の航行で `uncaught_error_previous_run` として書く。
///
/// **記録の失敗でアプリを止めない。** どの公開メソッドも例外を投げない。
class UncaughtErrorJournal {
  /// 1回の起動で保持する未報告の件数。同じ例外が毎フレーム起きても
  /// メモリとログを使い切らないよう、古いものから捨てる。
  static const defaultMaxUnreported = 50;

  /// ファイルへ残す件数の上限。
  static const defaultMaxPersisted = 50;

  final int maxUnreported;
  final int maxPersisted;
  final Future<File?> Function() _fileProvider;

  /// 同じ例外を記録し直すまでの間隔。
  ///
  /// 描画のたびに同じ例外が起きると、1件ごとにファイルの書き直しと診断ログへの
  /// 追記が走り、診断ログの上限(maxSessionDiagnosticEvents)を食い潰して
  /// 警告・測位の記録まで欠けさせる。診断ログの書き込み自体が例外を出すと
  /// 記録→例外が繰り返す。同じ例外は間隔ごとに1件だけ残し、間の回数は数える。
  static const repeatWindow = Duration(seconds: 60);

  /// 間引きのために覚えておく例外の種類の上限。
  static const maxTrackedRepeatKeys = 100;

  final ListQueue<UncaughtErrorRecord> _unreported = ListQueue();
  final Map<String, ({DateTime lastRecordedAt, int suppressed})> _repeats = {};
  final StreamController<void> _changes = StreamController<void>.broadcast();
  Future<void> _persistQueue = Future.value();
  int _droppedCount = 0;

  UncaughtErrorJournal({
    required Future<File?> Function() fileProvider,
    this.maxUnreported = defaultMaxUnreported,
    this.maxPersisted = defaultMaxPersisted,
  }) : _fileProvider = fileProvider;

  /// 新しい記録が入ったことの通知。中身は [drainUnreported] で取る。
  Stream<void> get changes => _changes.stream;

  /// 上限を超えて捨てた件数(診断で「欠けている」ことを示す)。
  int get droppedCount => _droppedCount;

  /// 例外を1件記録する。同期的に戻り、ファイル書き込みは裏で直列に行う。
  void record(
    Object error,
    StackTrace? stackTrace, {
    required String source,
    DateTime? at,
  }) {
    try {
      var entry = UncaughtErrorRecord.capture(
        error,
        stackTrace,
        source: source,
        at: at,
      );
      final key = entry.repeatKey;
      final previous = _repeats[key];
      if (previous != null &&
          entry.at.difference(previous.lastRecordedAt) < repeatWindow) {
        _repeats[key] = (
          lastRecordedAt: previous.lastRecordedAt,
          suppressed: previous.suppressed + 1,
        );
        return;
      }
      if (previous != null && previous.suppressed > 0) {
        entry = entry.withSuppressedRepeats(previous.suppressed);
      }
      _repeats.remove(key);
      _repeats[key] = (lastRecordedAt: entry.at, suppressed: 0);
      while (_repeats.length > maxTrackedRepeatKeys) {
        _repeats.remove(_repeats.keys.first);
      }
      _enqueue(entry);
      _persistQueue = _persistQueue.then((_) => _append(entry));
    } catch (_) {
      // 記録の失敗でアプリを止めない。
    }
  }

  /// 前回の起動で残った記録を読み出し、未報告へ積む。
  ///
  /// ファイルはここでは消さない。航行せずに終わった起動でも記録を失わない
  /// よう、診断ログへ書けた時点([drainUnreported])で空にする。
  Future<void> loadPreviousRun() async {
    try {
      final file = await _fileProvider();
      if (file == null || !await file.exists()) return;
      final lines = await file.readAsLines();
      for (final line in lines) {
        final parsed = UncaughtErrorRecord.tryParse(line);
        if (parsed != null) _enqueue(parsed.asPreviousRun());
      }
    } catch (_) {
      // 読めなくても起動は続ける。
    }
  }

  /// 未報告の記録をすべて取り出す。取り出した分はファイルからも消す。
  ///
  /// 消去は書き込みと同じ直列キューに積むので、取り出した後に起きた
  /// 例外の追記は消去の後に行われ、失われない。
  List<UncaughtErrorRecord> drainUnreported() {
    final drained = _unreported.toList(growable: false);
    _unreported.clear();
    if (drained.isNotEmpty) {
      _persistQueue = _persistQueue.then((_) => _clearFile());
    }
    return drained;
  }

  /// アカウントとデータの削除用。未報告の記録とファイルをすべて消す。
  Future<void> clearAll() {
    _unreported.clear();
    _droppedCount = 0;
    _persistQueue = _persistQueue.then((_) => _clearFile());
    return _persistQueue;
  }

  /// テスト用: 裏で進んでいるファイル書き込みの完了を待つ。
  Future<void> flushForTest() => _persistQueue;

  void _enqueue(UncaughtErrorRecord entry) {
    _unreported.add(entry);
    while (_unreported.length > maxUnreported) {
      _unreported.removeFirst();
      _droppedCount += 1;
    }
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> _clearFile() async {
    try {
      final file = await _fileProvider();
      if (file != null && await file.exists()) await file.writeAsString('');
    } catch (_) {
      // 消せなくても続ける。次回に重複して報告されるだけである。
    }
  }

  Future<void> _append(UncaughtErrorRecord entry) async {
    try {
      final file = await _fileProvider();
      if (file == null) return;
      final existing =
          await file.exists() ? await file.readAsLines() : const <String>[];
      final kept = [
        ...existing.where((line) => line.trim().isNotEmpty),
        jsonEncode(entry.toJson()),
      ];
      final trimmed = kept.length <= maxPersisted
          ? kept
          : kept.sublist(kept.length - maxPersisted);
      await file.writeAsString('${trimmed.join('\n')}\n', flush: true);
    } catch (_) {
      // 端末の容量不足などで書けなくても続ける。
    }
  }
}

Future<File?> _defaultJournalFile() async {
  final directory = await getApplicationSupportDirectory();
  return File('${directory.path}/uncaught_errors.jsonl');
}

/// アプリ全体で1つの記録先。
final appUncaughtErrorJournal =
    UncaughtErrorJournal(fileProvider: _defaultJournalFile);

/// Flutter の2つの例外の出口に記録を差し込む。
///
/// 既存のハンドラ(コンソール表示・テストの検出など)は必ず呼び続け、
/// 未処理の扱い(`PlatformDispatcher.onError` の戻り値)も変えない。
/// 記録を足すだけで、アプリの挙動は変えない。
void installUncaughtErrorHandlers(UncaughtErrorJournal journal) {
  final previousFlutterHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    journal.record(details.exception, details.stack, source: 'flutter');
    if (previousFlutterHandler != null) {
      previousFlutterHandler(details);
    } else {
      FlutterError.presentError(details);
    }
  };
  final previousPlatformHandler = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    journal.record(error, stackTrace, source: 'platform');
    return previousPlatformHandler?.call(error, stackTrace) ?? false;
  };
}
