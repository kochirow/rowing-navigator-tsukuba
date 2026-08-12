import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../config/log_config.dart';
import '../models/session_model.dart';

typedef ShareInvoker = Future<ShareResult> Function(ShareParams params);

class SessionExportException implements Exception {
  final String message;

  const SessionExportException(this.message);

  @override
  String toString() => message;
}

/// セッションをGPX/CSV/診断ZIPへ書き出して共有するサービス。
class GpxExportService {
  final Future<Directory> Function() _temporaryDirectoryProvider;
  final ShareInvoker _share;

  GpxExportService({
    Future<Directory> Function()? temporaryDirectoryProvider,
    ShareInvoker? share,
  })  : _temporaryDirectoryProvider =
            temporaryDirectoryProvider ?? getTemporaryDirectory,
        _share = share ?? SharePlus.instance.share;

  /// GPX 1.1 形式の文字列を生成する(純粋関数・テスト可能)
  String buildGpx(Session session) {
    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buffer.writeln(
        '<gpx version="1.1" creator="Rowing Navigator" xmlns="http://www.topografix.com/GPX/1/1">');
    buffer.writeln('  <metadata>');
    buffer.writeln(
        '    <time>${session.startedAt.toUtc().toIso8601String()}</time>');
    buffer.writeln('  </metadata>');
    buffer.writeln('  <trk>');
    buffer.writeln('    <name>Rowing ${_formatDate(session.startedAt)}'
        ' (${session.boatTypeName})</name>');
    buffer.writeln('    <type>Rowing</type>');
    buffer.writeln('    <trkseg>');
    for (final p in session.points) {
      buffer.writeln('      <trkpt lat="${p.lat}" lon="${p.lng}">');
      buffer.writeln('        <time>${p.t.toUtc().toIso8601String()}</time>');
      buffer.writeln('      </trkpt>');
    }
    buffer.writeln('    </trkseg>');
    buffer.writeln('  </trk>');
    buffer.writeln('</gpx>');
    return buffer.toString();
  }

  /// CSV形式の文字列を生成する(従来形式と互換)
  String buildCsv(Session session) {
    final buffer = StringBuffer();
    buffer.writeln(
        'timestamp,lat,lng,heading,speed,spm,safety_level,boat_type,seat_pos');
    for (final p in session.points) {
      buffer.writeln([
        p.t.toIso8601String(),
        p.lat,
        p.lng,
        p.heading,
        p.speed,
        p.spm ?? '',
        p.safetyLevel,
        session.boatTypeName,
        session.seatPosLabel,
      ].map(_csvCell).join(','));
    }
    return buffer.toString();
  }

  /// 診断ZIPに含めるファイルを生成する。
  Map<String, String> buildDiagnosticFiles(
    Session session, {
    String exportPlatform = 'unknown',
    String exportPlatformVersion = 'unknown',
  }) {
    final metadata = session.diagnosticMetadata;
    final settings = Map<String, dynamic>.from(
      metadata?.settingsSnapshot ?? const <String, dynamic>{},
    );
    final fixedObstacleProfile = settings.remove('fixedObstacleProfile');
    final manifest = <String, dynamic>{
      'diagnosticPackageSchemaVersion': 5,
      'diagnosticEventSchemaVersion': diagnosticEventSchemaVersion,
      'diagnosticCatalogVersion': diagnosticCatalogVersion,
      'sessionSchemaVersion': session.schemaVersion,
      'session': {
        'id': session.id,
        'startedAt': session.startedAt.toUtc().toIso8601String(),
        'endedAt': session.endedAt.toUtc().toIso8601String(),
        'isComplete': session.isComplete,
        'boatType': session.boatTypeName,
        'seatPosition': session.seatPosLabel,
        'pointCount': session.points.length,
        'alertEventCount': session.alertEvents.length,
        'diagnosticEventCount': session.diagnosticEvents.length,
      },
      'logging': {
        'eventSchemaVersion': diagnosticEventSchemaVersion,
        'catalogVersion': diagnosticCatalogVersion,
        'ordering': 'seq is shared across alerts.jsonl and events.jsonl',
        'diagnosticEventCount': session.diagnosticEvents.length,
        'alertEventCount': session.alertEvents.length,
        'diagnosticEventDroppedCount':
            settings['diagnosticEventDroppedCount'] ?? 0,
        'alertEventDroppedCount': settings['alertEventDroppedCount'] ?? 0,
      },
      'app': {
        'version': metadata?.appVersion ?? 'unknown',
        'buildNumber': metadata?.buildNumber ?? 'unknown',
        'gitCommitSha': metadata?.gitCommitSha ?? 'unknown',
        'buildTimestampUtc': metadata?.buildTimestampUtc ?? 'unknown',
        'buildFlavor': metadata?.buildFlavor ?? 'unknown',
      },
      'device': {
        'platform': metadata?.platform ?? exportPlatform,
        // 解析時ではなく、航行開始時のOSを優先する。
        'operatingSystemVersion':
            metadata?.operatingSystemVersion ?? exportPlatformVersion,
        'class': 'mobile',
      },
      'hazardProfile': {
        'version': metadata?.hazardProfileVersion ?? 0,
        'sha256': metadata?.hazardProfileSha256 ?? 'unknown',
      },
      'fixedObstacleProfile': fixedObstacleProfile is Map
          ? Map<String, dynamic>.from(fixedObstacleProfile)
          : {
              'version': metadata?.hazardProfileVersion ?? 0,
              'sha256': metadata?.hazardProfileSha256 ?? 'unknown',
              'snapshotAvailable': false,
            },
      'settings': settings,
      'alertEpisodeRatings': session.alertEpisodeRatings,
      'privacy': {
        'containsPreciseRoute': true,
        'containsDeviceInformation': true,
        'automaticUpload': false,
        'otherBoatIdentifiers': 'session-local aliases only',
      },
    };

    final track = StringBuffer()
      ..writeln([
        'timestamp',
        'elapsed_ms',
        'raw_lat',
        'raw_lng',
        'filtered_lat',
        'filtered_lng',
        'speed_mps',
        'heading_deg',
        'gnss_accuracy_m',
        'speed_accuracy_mps',
        'heading_accuracy_deg',
        'gnss_quality',
        'position_filter_result',
        'estimate_uncertainty_m',
        'estimate_innovation_m',
        'estimate_disposition',
        'estimate_nis',
        'raw_gnss_speed_mps',
        'imu_confidence',
        'imu_quality',
        'distance_per_stroke_m',
        'catch_speed_loss_mps',
        'late_drive_speed_gain_mps',
        'recovery_speed_retention',
        'spm',
        'safety_level',
      ].join(','));
    for (final point in session.points) {
      track.writeln([
        point.t.toUtc().toIso8601String(),
        point.elapsedMs ?? point.t.difference(session.startedAt).inMilliseconds,
        point.rawLat ?? '',
        point.rawLng ?? '',
        point.lat,
        point.lng,
        point.speed,
        point.heading,
        point.gnssAccuracyMeters ?? '',
        point.speedAccuracyMetersPerSecond ?? '',
        point.headingAccuracyDegrees ?? '',
        point.gnssQuality ?? '',
        point.positionFilterResult ?? '',
        point.estimateUncertaintyMeters ?? '',
        point.estimateInnovationMeters ?? '',
        point.estimateDisposition ?? '',
        point.estimateNormalizedInnovationSquared ?? '',
        point.rawGnssSpeedMetersPerSecond ?? '',
        point.imuConfidence ?? '',
        point.imuQuality ?? '',
        point.distancePerStrokeMeters ?? '',
        point.catchSpeedLossMetersPerSecond ?? '',
        point.lateDriveSpeedGainMetersPerSecond ?? '',
        point.recoverySpeedRetention ?? '',
        point.spm ?? '',
        point.safetyLevel,
      ].map(_csvCell).join(','));
    }

    final alertAliases = <String, String>{};
    final targetAliases = <String, String>{};
    String aliasFor(Map<String, String> aliases, String prefix, String raw) =>
        aliases.putIfAbsent(raw, () => '$prefix-${aliases.length + 1}');
    final alertLines = session.alertEvents.map((event) {
      final json = event.toJson();
      if (_isOtherBoatCategory(event.category)) {
        json['alertId'] = aliasFor(alertAliases, 'alert', event.alertId);
        final target = event.targetRef;
        if (target != null) {
          json['targetRef'] = target.startsWith('boat-')
              ? target
              : aliasFor(targetAliases, 'boat', target);
        }
      }
      return jsonEncode(json);
    }).join('\n');
    final eventLines = session.diagnosticEvents
        .map((event) => jsonEncode(event.toJson()))
        .join(
          '\n',
        );

    return {
      'manifest.json': const JsonEncoder.withIndent('  ').convert(manifest),
      'diagnostic_event_catalog.json':
          const JsonEncoder.withIndent('  ').convert(diagnosticEventCatalog),
      'track.csv': track.toString(),
      'alerts.jsonl': alertLines.isEmpty ? '' : '$alertLines\n',
      'events.jsonl': eventLines.isEmpty ? '' : '$eventLines\n',
    };
  }

  Uint8List buildDiagnosticArchive(
    Session session, {
    String exportPlatform = 'unknown',
    String exportPlatformVersion = 'unknown',
  }) {
    final archive = Archive();
    final files = buildDiagnosticFiles(
      session,
      exportPlatform: exportPlatform,
      exportPlatformVersion: exportPlatformVersion,
    );
    for (final entry in files.entries) {
      final bytes = utf8.encode(entry.value);
      archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
    }
    final encoded = ZipEncoder().encode(archive);
    if (encoded == null || encoded.isEmpty) {
      throw const SessionExportException('診断ZIPを作成できませんでした。');
    }
    return Uint8List.fromList(encoded);
  }

  Future<ShareResult> shareAsGpx(
    Session session, {
    required Rect sharePositionOrigin,
  }) async {
    return _writeAndShare(
      fileName: 'rowing_${session.id}.gpx',
      bytes: utf8.encode(buildGpx(session)),
      mimeType: 'application/gpx+xml',
      subject: '航行記録 ${_formatDate(session.startedAt)}',
      sharePositionOrigin: sharePositionOrigin,
    );
  }

  Future<ShareResult> shareAsCsv(
    Session session, {
    required Rect sharePositionOrigin,
  }) async {
    return _writeAndShare(
      fileName: 'rowing_${session.id}.csv',
      bytes: utf8.encode(buildCsv(session)),
      mimeType: 'text/csv',
      subject: '航行記録 ${_formatDate(session.startedAt)}',
      sharePositionOrigin: sharePositionOrigin,
    );
  }

  Future<ShareResult> shareDiagnosticPackage(
    Session session, {
    required Rect sharePositionOrigin,
  }) async {
    final bytes = buildDiagnosticArchive(
      session,
      exportPlatform: Platform.operatingSystem,
      exportPlatformVersion: Platform.operatingSystemVersion,
    );
    return _writeAndShare(
      fileName: 'rowing_diagnostics_${session.id}.zip',
      bytes: bytes,
      mimeType: 'application/zip',
      subject: '航行診断データ ${_formatDate(session.startedAt)}',
      sharePositionOrigin: sharePositionOrigin,
    );
  }

  Future<ShareResult> _writeAndShare({
    required String fileName,
    required List<int> bytes,
    required String mimeType,
    required String subject,
    required Rect sharePositionOrigin,
  }) async {
    if (sharePositionOrigin.isEmpty ||
        !sharePositionOrigin.left.isFinite ||
        !sharePositionOrigin.top.isFinite) {
      throw const SessionExportException('共有ボタンの表示位置を取得できませんでした。');
    }
    if (bytes.isEmpty) {
      throw const SessionExportException('共有するファイルが空です。');
    }
    final dir = await _temporaryDirectoryProvider();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    if (!await file.exists() || await file.length() <= 0) {
      throw const SessionExportException('共有ファイルを作成できませんでした。');
    }
    return _share(ShareParams(
      files: [XFile(file.path, mimeType: mimeType)],
      subject: subject,
      sharePositionOrigin: sharePositionOrigin,
    ));
  }

  static bool _isOtherBoatCategory(String category) =>
      category == 'other_boat' || category == 'other_boat_track_lost';

  static String _csvCell(Object? value) {
    final text = value?.toString() ?? '';
    if (!text.contains(RegExp('[,"\\r\\n]'))) return text;
    return '"${text.replaceAll('"', '""')}"';
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/'
        '${dt.day.toString().padLeft(2, '0')}';
  }
}
