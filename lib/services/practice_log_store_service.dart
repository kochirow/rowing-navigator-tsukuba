import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../config/practice_log_config.dart';
import '../models/practice_log_model.dart';

/// 一括ログをJSONL追記で保存する。書込失敗は呼出側が握りつぶせるよう、
/// 本サービスは安全判定・RTDB・地図モデルを参照しない。
class PracticeLogStoreService {
  final Future<Directory> Function() _documentsDirectoryProvider;
  PracticeLogStoreService(
      {Future<Directory> Function()? documentsDirectoryProvider})
      : _documentsDirectoryProvider =
            documentsDirectoryProvider ?? getApplicationDocumentsDirectory;

  Future<Directory> _root() async {
    final docs = await _documentsDirectoryProvider();
    final dir = Directory('${docs.path}/practice_logs');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _dir(String id) async {
    if (!RegExp(r'^practice_[0-9]{8}_[0-9]{4,6}$').hasMatch(id)) {
      throw ArgumentError.value(id, 'id');
    }
    final dir = Directory('${(await _root()).path}/$id');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> create(PracticeLog log) async {
    final dir = await _dir(log.id);
    await _writeMeta(File('${dir.path}/meta.json'), log);
  }

  Future<void> append(String id,
      {Iterable<PracticeLogPoint> points = const [],
      Iterable<PracticeLogEvent> events = const []}) async {
    final dir = await _dir(id);
    final pointLines = points.map(practiceLogJsonLine).join('\n');
    final eventLines = events.map(practiceLogJsonLine).join('\n');
    if (pointLines.isNotEmpty) {
      await File('${dir.path}/track.jsonl')
          .writeAsString('$pointLines\n', mode: FileMode.append, flush: true);
    }
    if (eventLines.isNotEmpty) {
      await File('${dir.path}/events.jsonl')
          .writeAsString('$eventLines\n', mode: FileMode.append, flush: true);
    }
  }

  Future<void> checkpoint(PracticeLog log) async =>
      _writeMeta(File('${(await _dir(log.id)).path}/meta.json'), log);
  Future<void> complete(PracticeLog log, DateTime endedAt) =>
      checkpoint(log.copyWith(endedAt: endedAt.toUtc(), isComplete: true));

  /// 共有した時刻を meta.json へ書く。記録中のログには呼ばない
  /// (記録側が持つ控えで meta.json を書き直すため、印が消える)。
  /// 読めない・無いログは何もしない。
  Future<void> markDiagnosticsShared(String id, DateTime at) async {
    final file = File('${(await _dir(id)).path}/meta.json');
    if (!await file.exists()) return;
    final log = PracticeLog.fromJson(
        Map<String, dynamic>.from(jsonDecode(await file.readAsString())));
    await _writeMeta(file, log.copyWith(diagnosticsSharedAt: () => at));
  }

  Future<List<PracticeLog>> list() async {
    final root = await _root();
    final result = <PracticeLog>[];
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final file = File('${entity.path}/meta.json');
      if (!await file.exists()) continue;
      try {
        var log = PracticeLog.fromJson(
            Map<String, dynamic>.from(jsonDecode(await file.readAsString())));
        // 艇の位置の数が無い古い完了済みの記録は、一度だけ中身から数えて meta へ残す。
        // 記録中のログは書込が続き、記録側が meta を書き直すので触らない。
        if (log.isComplete && log.livePointCount == null) {
          try {
            log = log.copyWith(
                livePointCount:
                    await _countLivePoints(File('${entity.path}/track.jsonl')));
            await _writeMeta(file, log);
          } catch (_) {/* 数えられなければ不明のまま。対象には入れない */}
        }
        result.add(log);
      } catch (_) {/* broken logs stay untouched */}
    }
    result.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return result;
  }

  Future<
      ({
        PracticeLog log,
        List<PracticeLogPoint> points,
        List<PracticeLogEvent> events
      })> read(String id) async {
    final dir = await _dir(id);
    final meta = PracticeLog.fromJson(Map<String, dynamic>.from(
        jsonDecode(await File('${dir.path}/meta.json').readAsString())));
    return (
      log: meta,
      points: await _readLines<PracticeLogPoint>(
          File('${dir.path}/track.jsonl'),
          (json) => PracticeLogPoint.fromJson(json)),
      events: await _readLines<PracticeLogEvent>(
          File('${dir.path}/events.jsonl'),
          (json) => PracticeLogEvent.fromJson(json))
    );
  }

  Future<int> _countLivePoints(File file) async {
    if (!await file.exists()) return 0;
    var count = 0;
    await for (final line in file
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (line.contains('"source":"live"')) count++;
    }
    return count;
  }

  Future<List<T>> _readLines<T>(
      File file, T Function(Map<String, dynamic>) parse) async {
    if (!await file.exists()) return [];
    final result = <T>[];
    await for (final line in file
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      try {
        result.add(parse(Map<String, dynamic>.from(jsonDecode(line))));
      } catch (_) {/* preserve other valid JSONL rows */}
    }
    return result;
  }

  Future<void> delete(String id) async {
    final dir = await _dir(id);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<void> deleteAllPracticeLogs() async {
    final root = await _root();
    if (await root.exists()) await root.delete(recursive: true);
  }

  Future<void> prune() async {
    final logs = await list();
    for (final old in logs.skip(maxStoredPracticeLogs)) {
      await delete(old.id);
    }
  }

  Future<void> _writeMeta(File file, PracticeLog log) async {
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(log.toJson()),
        flush: true);
    await temp.rename(file.path);
  }
}
