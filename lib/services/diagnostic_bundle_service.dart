import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../config/log_export_config.dart';
import '../models/message_model.dart';
import '../models/practice_log_model.dart';
import '../models/session_model.dart';
import 'gpx_export_service.dart';

// # 未送信の診断ログをまとめて送る
//
// 記録ごとの診断ZIP(gpx_export_service.dart)と同じ5ファイルを、
// 記録ごとのフォルダ `rowing_diagnostics_<id>/` に入れて1つのZIPにする。
// 受け取った側は、今の保存場所(実機テストログデータ/日付/rowing_diagnostics_*)へ
// そのまま展開できる。自動送信はしない。共有先は利用者が選ぶ。
//
// 監視端末の監視ログ(practice_log_export_service.dart)も同じZIPに入れる。
// こちらは記録ごとのフォルダ `<監視ログのid>/`(例: practice_20261029_063000)に
// 監視ログ単体の共有と同じ4ファイルを置く。

/// 練習時間 [秒]。アプリ内の「練習時間」(艇が動いていた時間)で数える。
/// 古い記録で動いていた時間が無いときは、記録の長さで代える。
double practiceSecOf(Session s) => s.summary.movingTimeSec > 0
    ? s.summary.movingTimeSec
    : s.summary.durationSec;

/// まとめて送る対象(練習時間・距離の下限を満たし、未送信)か。
bool isBulkLogExportTarget(Session s) =>
    !s.isDiagnosticsShared && isBulkLogExportCandidate(s);

/// 送信済みかどうかを問わず、まとめて送る条件(練習時間・距離)を満たすか。
bool isBulkLogExportCandidate(Session s) =>
    practiceSecOf(s) >= bulkLogExportMinPracticeSec &&
    s.summary.totalDistanceMeters >= bulkLogExportMinDistanceMeters;

/// 未送信でまとめて送る対象の記録(古い順)。
List<Session> pendingBulkLogExports(Iterable<Session> sessions) =>
    sessions.where(isBulkLogExportTarget).toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));

/// 監視ログの時間 [秒]。記録した長さで数える(監視端末は動かないので距離は使わない)。
double practiceLogSecOf(PracticeLog log) {
  final end = log.endedAt;
  return end == null ? 0 : end.difference(log.startedAt).inMilliseconds / 1000;
}

/// 未送信でまとめて送る対象の監視ログか。
///
/// 記録中・未完了のログは含めない。記録中のログは書き込みが続いており、
/// 送信済みの印も記録側に上書きされる。時間の下限は練習記録と同じ15分。
bool isBulkPracticeLogTarget(PracticeLog log) =>
    log.isComplete &&
    !log.isDiagnosticsShared &&
    practiceLogSecOf(log) >= bulkLogExportMinPracticeSec;

/// 未送信でまとめて送る対象の監視ログ(古い順)。
List<PracticeLog> pendingBulkPracticeLogs(Iterable<PracticeLog> logs) =>
    logs.where(isBulkPracticeLogTarget).toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));

/// ZIPへ入れる監視ログ1件。[files] は `PracticeLogExportService.buildFiles` の結果。
class PracticeLogBundleInput {
  final PracticeLog log;
  final Map<String, String> files;

  const PracticeLogBundleInput({required this.log, required this.files});
}

/// まとめたZIPの1つ。
class DiagnosticBundle {
  final String fileName;
  final Uint8List bytes;
  final List<String> sessionIds;
  final List<String> practiceLogIds;

  const DiagnosticBundle({
    required this.fileName,
    required this.bytes,
    required this.sessionIds,
    this.practiceLogIds = const [],
  });
}

typedef BundleShareInvoker = Future<ShareResult> Function(ShareParams params);

class DiagnosticBundleService {
  final Future<Directory> Function() _temporaryDirectoryProvider;
  final BundleShareInvoker _share;

  DiagnosticBundleService({
    Future<Directory> Function()? temporaryDirectoryProvider,
    BundleShareInvoker? share,
  })  : _temporaryDirectoryProvider =
            temporaryDirectoryProvider ?? getTemporaryDirectory,
        _share = share ?? SharePlus.instance.share;

  /// ZIPを作る(純粋関数・テスト可能)。[maxZipBytes] を超えないよう記録単位で分ける。
  /// 1記録だけで上限を超えるときは、その記録だけのZIPにする(分けられないため)。
  static List<DiagnosticBundle> buildBundles(
    List<Session> sessions, {
    List<PracticeLogBundleInput> practiceLogs = const [],
    required DateTime createdAt,
    int maxZipBytes = bulkLogExportMaxZipBytes,
    String exportPlatform = 'unknown',
    String exportPlatformVersion = 'unknown',
  }) {
    if (sessions.isEmpty && practiceLogs.isEmpty) return const [];
    final exporter = GpxExportService();
    final entries = <_Entry>[];
    for (final s in sessions) {
      final files = exporter.buildDiagnosticFiles(s,
          exportPlatform: exportPlatform,
          exportPlatformVersion: exportPlatformVersion);
      final folder = 'rowing_diagnostics_${s.id}';
      final encoded = <String, List<int>>{
        for (final e in files.entries) '$folder/${e.key}': utf8.encode(e.value),
      };
      entries.add(_Entry(s, encoded, _zip(encoded).length));
    }
    for (final p in practiceLogs) {
      final folder = p.log.id;
      final encoded = <String, List<int>>{
        for (final e in p.files.entries)
          '$folder/${e.key}': utf8.encode(e.value),
      };
      entries.add(_Entry.practiceLog(p.log, encoded, _zip(encoded).length));
    }

    // 先頭から順に詰める。ZIPの見出しと bundle_manifest の分の余裕を残す。
    const overhead = 64 * 1024;
    final groups = <List<_Entry>>[];
    var current = <_Entry>[];
    var size = overhead;
    for (final e in entries) {
      if (current.isNotEmpty && size + e.compressedBytes > maxZipBytes) {
        groups.add(current);
        current = [];
        size = overhead;
      }
      current.add(e);
      size += e.compressedBytes;
    }
    groups.add(current);

    final stamp = _stamp(createdAt);
    return [
      for (var i = 0; i < groups.length; i++)
        _bundle(groups[i],
            fileName: groups.length == 1
                ? 'rowing_diagnostics_bundle_${stamp}_${groups[i].length}.zip'
                : 'rowing_diagnostics_bundle_${stamp}_part${i + 1}of${groups.length}.zip',
            createdAt: createdAt,
            part: i + 1,
            partCount: groups.length),
    ];
  }

  /// [buildBundles] を別 isolate で行う(記録が多いと数秒かかり、画面が固まるため)。
  Future<List<DiagnosticBundle>> buildBundlesInBackground(
          List<Session> sessions,
          {List<PracticeLogBundleInput> practiceLogs = const []}) =>
      compute(
          _buildInIsolate,
          _BuildRequest(sessions, practiceLogs, DateTime.now(),
              Platform.operatingSystem, Platform.operatingSystemVersion));

  /// 作ったZIPを一時フォルダへ書き、共有シートへまとめて渡す。
  Future<ShareResult> share(
    List<DiagnosticBundle> bundles, {
    required Rect sharePositionOrigin,
  }) async {
    if (bundles.isEmpty) {
      throw const SessionExportException('送る記録がありません。');
    }
    if (sharePositionOrigin.isEmpty ||
        !sharePositionOrigin.left.isFinite ||
        !sharePositionOrigin.top.isFinite) {
      throw const SessionExportException('共有ボタンの表示位置を取得できませんでした。');
    }
    final dir = await _temporaryDirectoryProvider();
    final files = <XFile>[];
    for (final b in bundles) {
      final file = File('${dir.path}/${b.fileName}');
      await file.writeAsBytes(b.bytes, flush: true);
      if (!await file.exists() || await file.length() <= 0) {
        throw const SessionExportException('共有ファイルを作成できませんでした。');
      }
      files.add(XFile(file.path, mimeType: 'application/zip'));
    }
    final count = bundles.fold<int>(
        0, (a, b) => a + b.sessionIds.length + b.practiceLogIds.length);
    return _share(ShareParams(
      files: files,
      subject: '航行診断データ $count件',
      sharePositionOrigin: sharePositionOrigin,
    ));
  }

  static DiagnosticBundle _bundle(
    List<_Entry> group, {
    required String fileName,
    required DateTime createdAt,
    required int part,
    required int partCount,
  }) {
    final manifest = {
      'bundleSchemaVersion': 1,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'part': part,
      'partCount': partCount,
      'appVersion': Message.currentAppVersion,
      'criteria': {
        'minPracticeSec': bulkLogExportMinPracticeSec,
        'minDistanceMeters': bulkLogExportMinDistanceMeters,
      },
      'sessions': [
        for (final e in group)
          if (e.session case final session?)
            {
              'id': session.id,
              'folder': 'rowing_diagnostics_${session.id}',
              'startedAt': session.startedAt.toUtc().toIso8601String(),
              'practiceSec': practiceSecOf(session).round(),
              'distanceMeters': session.summary.totalDistanceMeters.round(),
              'boatType': session.boatTypeName,
            },
      ],
      // 監視端末の監視ログ。無いときも空の配列で出し、受け取る側が項目の有無で迷わない。
      'practiceLogs': [
        for (final e in group)
          if (e.practiceLog case final log?)
            {
              'id': log.id,
              'folder': log.id,
              'startedAt': log.startedAt.toUtc().toIso8601String(),
              'durationSec': practiceLogSecOf(log).round(),
            },
      ],
      'privacy': {
        'containsPreciseRoute': true,
        'containsDeviceInformation': true,
        'automaticUpload': false,
      },
    };
    final files = <String, List<int>>{
      'bundle_manifest.json':
          utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest)),
      for (final e in group) ...e.files,
    };
    return DiagnosticBundle(
      fileName: fileName,
      bytes: _zip(files),
      sessionIds: [
        for (final e in group)
          if (e.session case final session?) session.id
      ],
      practiceLogIds: [
        for (final e in group)
          if (e.practiceLog case final log?) log.id
      ],
    );
  }

  static Uint8List _zip(Map<String, List<int>> files) {
    final archive = Archive();
    for (final e in files.entries) {
      archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
    }
    final encoded = ZipEncoder().encode(archive);
    if (encoded == null || encoded.isEmpty) {
      throw const SessionExportException('診断ZIPを作成できませんでした。');
    }
    return Uint8List.fromList(encoded);
  }

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    final l = t.toLocal();
    return '${l.year}${two(l.month)}${two(l.day)}-${two(l.hour)}${two(l.minute)}';
  }
}

class _Entry {
  final Session? session;
  final PracticeLog? practiceLog;
  final Map<String, List<int>> files;
  final int compressedBytes;
  _Entry(Session this.session, this.files, this.compressedBytes)
      : practiceLog = null;
  _Entry.practiceLog(
      PracticeLog this.practiceLog, this.files, this.compressedBytes)
      : session = null;
}

class _BuildRequest {
  final List<Session> sessions;
  final List<PracticeLogBundleInput> practiceLogs;
  final DateTime createdAt;
  final String platform;
  final String platformVersion;
  _BuildRequest(this.sessions, this.practiceLogs, this.createdAt, this.platform,
      this.platformVersion);
}

List<DiagnosticBundle> _buildInIsolate(_BuildRequest r) =>
    DiagnosticBundleService.buildBundles(r.sessions,
        practiceLogs: r.practiceLogs,
        createdAt: r.createdAt,
        exportPlatform: r.platform,
        exportPlatformVersion: r.platformVersion);
