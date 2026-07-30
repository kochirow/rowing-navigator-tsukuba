import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/practice_log_model.dart';
import '../models/message_model.dart';

class PracticeLogExportException implements Exception {
  final String message;
  const PracticeLogExportException(this.message);
  @override
  String toString() => message;
}

typedef PracticeLogShareInvoker = Future<ShareResult> Function(
    ShareParams params);

class PracticeLogExportService {
  final Future<Directory> Function() _temporaryDirectoryProvider;
  final PracticeLogShareInvoker _share;
  PracticeLogExportService(
      {Future<Directory> Function()? temporaryDirectoryProvider,
      PracticeLogShareInvoker? share})
      : _temporaryDirectoryProvider =
            temporaryDirectoryProvider ?? getTemporaryDirectory,
        _share = share ?? SharePlus.instance.share;

  Map<String, String> buildFiles(PracticeLog log,
      Iterable<PracticeLogPoint> points, Iterable<PracticeLogEvent> events,
      {bool anonymized = false}) {
    final pointList = points.toList();
    final eventList = events.toList();
    final aliases = <String, String>{};
    final usedAliases = <String>{};
    // 表示名は利用者が付けるもので、既定の「名前未設定」のまま出す艇もある。
    // 衝突したまま同じ列名にすると、事故検証で別の艇の航跡を1本に混ぜてしまう。
    // 必ず艇ごとに異なる名前へ振り分ける。
    String alias(String id, String? displayName) => aliases.putIfAbsent(id, () {
          final base = anonymized || displayName == null || displayName.isEmpty
              ? 'boat'
              : displayName;
          var candidate = anonymized ? 'boat-${aliases.length + 1}' : base;
          var suffix = 2;
          while (!usedAliases.add(candidate)) {
            candidate = '$base-$suffix';
            suffix++;
          }
          return candidate;
        });
    final boatPoints = <String, List<PracticeLogPoint>>{};
    for (final point
        in pointList.where((p) => p.source == PracticeLogSource.live)) {
      (boatPoints[point.boatId] ??= []).add(point);
    }
    final boats = boatPoints.entries.map((entry) {
      final values = entry.value;
      final caps = <String>{
        'course',
        'accuracy',
        'session_sequence',
        'display_name'
      };
      if (values.any((p) => p.presentationState != null)) {
        caps.add('presentation_state');
      }
      final gaps = eventList
          .where((e) => e.type == 'gap' && e.details['boatId'] == entry.key)
          .toList();
      return {
        'alias': alias(entry.key, values.first.displayName),
        'sessionCount':
            values.map((p) => p.sessionId).whereType<String>().toSet().length,
        'pointCount': values.length,
        'firstSeenAt': values.first.t.toIso8601String(),
        'lastSeenAt': values.last.t.toIso8601String(),
        'gapCount': gaps.length,
        'missingSeconds': _missingSeconds(gaps),
        // 受信途絶(boat_lost)は終端が定まらないため missingSeconds に含めない。
        // 0 と読んで「欠測なし」と解釈されないよう、件数を併記する。
        'lostCount': eventList
            .where((e) =>
                e.type == 'boat_lost' && e.details['boatId'] == entry.key)
            .length,
        'capabilities': caps.toList()
      };
    }).toList();
    final manifest = {
      ...log.toJson(),
      'endedAt': log.endedAt?.toUtc().toIso8601String(),
      'app': {'version': Message.currentAppVersion, 'buildNumber': 'unknown'},
      'device': {
        'platform': Platform.operatingSystem,
        'operatingSystemVersion': Platform.operatingSystemVersion,
      },
      'hazardProfile': {
        'version': Message.currentProfileVersion,
        'sha256': 'unknown',
      },
      'protocol': {
        'positionProtocolVersion': 1,
        'presentationStateAvailable':
            pointList.any((p) => p.presentationState != null)
      },
      'boats': boats,
      'recorderGaps': eventList
          .where((e) => e.type == 'recorder_gap')
          .map((e) => e.details)
          .toList(),
      'anonymized': anonymized,
      'privacy': {
        'containsPreciseRoute': true,
        'automaticUpload': false,
        'scope': 'team_members_only'
      }
    };
    final tracks = StringBuffer()
      ..writeln(
          'utc_time,elapsed_ms,boat_alias,session_id,seq,lat,lng,speed_mps,course_deg,accuracy_m,battery,warn_band,warn_category,run_mode,ashore,age_sec,source');
    for (final p in pointList) {
      final warning = p.presentationState;
      tracks.writeln([
        p.t.toUtc().toIso8601String(),
        p.t.difference(log.startedAt).inMilliseconds,
        p.source == PracticeLogSource.observer
            ? 'observer'
            : alias(p.boatId, p.displayName),
        p.sessionId ?? '',
        p.sequence ?? '',
        p.lat,
        p.lng,
        p.speed ?? '',
        p.course ?? '',
        p.accuracy ?? '',
        p.battery ?? '',
        warning == null ? '' : warning.substring(0, 1),
        warning == null ? '' : warning.substring(1),
        p.safetyRunMode ?? '',
        p.audioSuppressedAshore ? 1 : '',
        p.ageSec,
        p.source.name
      ].map(_csv).join(','));
    }
    return {
      'practice_manifest.json':
          const JsonEncoder.withIndent('  ').convert(manifest),
      'boats.csv': '${[
        'boat_alias,session_count,point_count',
        ...boats.map((b) =>
            '${_csv(b['alias'])},${b['sessionCount']},${b['pointCount']}')
      ].join('\n')}\n',
      'tracks.csv': tracks.toString(),
      'events.jsonl': eventList.map((e) => jsonEncode(e.toJson())).join('\n') +
          (eventList.isEmpty ? '' : '\n')
    };
  }

  Uint8List buildArchive(PracticeLog log, Iterable<PracticeLogPoint> points,
      Iterable<PracticeLogEvent> events,
      {bool anonymized = false}) {
    final archive = Archive();
    for (final entry
        in buildFiles(log, points, events, anonymized: anonymized).entries) {
      final bytes = utf8.encode(entry.value);
      archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
    }
    final encoded = ZipEncoder().encode(archive);
    if (encoded == null || encoded.isEmpty) {
      throw const PracticeLogExportException('練習一括ログZIPを作成できませんでした。');
    }
    return Uint8List.fromList(encoded);
  }

  Future<ShareResult> share(PracticeLog log, Iterable<PracticeLogPoint> points,
      Iterable<PracticeLogEvent> events,
      {required Rect sharePositionOrigin, bool anonymized = false}) async {
    final directory = await _temporaryDirectoryProvider();
    final file = File('${directory.path}/${log.id}.zip');
    await file.writeAsBytes(
        buildArchive(log, points, events, anonymized: anonymized),
        flush: true);
    return _share(ShareParams(
        files: [XFile(file.path, mimeType: 'application/zip')],
        subject: '練習一括ログ ${log.id}',
        sharePositionOrigin: sharePositionOrigin));
  }

  /// gap イベントが持つ from/to から、実際に受信できなかった秒数を積算する。
  /// 算出できない行は足さない(0 を「欠測なし」と読ませないため、
  /// 件数は gapCount / lostCount で別に出す)。
  static double _missingSeconds(Iterable<PracticeLogEvent> gaps) {
    var total = 0.0;
    for (final gap in gaps) {
      final from = gap.details['from'];
      final to = gap.details['to'];
      if (from is! String || to is! String) continue;
      final seconds =
          DateTime.parse(to).difference(DateTime.parse(from)).inMilliseconds /
              1000;
      if (seconds > 0) total += seconds;
    }
    return total;
  }

  static String _csv(Object? value) {
    final text = value?.toString() ?? '';
    return text.contains(RegExp('[,"\\r\\n]'))
        ? '"${text.replaceAll('"', '""')}"'
        : text;
  }
}
