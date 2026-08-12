import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/session_model.dart';
import 'package:rowing_navigator/services/gpx_export_service.dart';
import 'package:share_plus/share_plus.dart';

Session makeSession() {
  final t0 = DateTime.utc(2026, 7, 7, 6, 0, 0);
  final points = [
    TrackPoint(
        t: t0,
        lat: 36.0670,
        lng: 140.2045,
        speed: 3,
        heading: 0,
        safetyLevel: 'safe'),
    TrackPoint(
        t: t0.add(const Duration(seconds: 1)),
        lat: 36.0671,
        lng: 140.2045,
        speed: 3,
        heading: 0,
        safetyLevel: 'safe'),
  ];
  return Session(
    id: 'test',
    startedAt: t0,
    endedAt: t0.add(const Duration(seconds: 1)),
    boatTypeName: 'r_1x',
    seatPosLabel: '1',
    points: points,
    summary: SessionSummary(
      totalDistanceMeters: 11,
      durationSec: 1,
      maxSpeed: 3,
      avgSpeed: 3,
      splits: const [],
      pieces: const [],
      alertCounts: const {},
    ),
  );
}

void main() {
  final exporter = GpxExportService();

  test('GPXに全記録点とヘッダが含まれる', () {
    final gpx = exporter.buildGpx(makeSession());
    expect(gpx, contains('<?xml version="1.0"'));
    expect(gpx, contains('<gpx version="1.1"'));
    expect(gpx, contains('lat="36.067"'));
    expect(gpx, contains('<type>Rowing</type>'));
    expect('trkpt'.allMatches(gpx).length, 4); // 開始・終了タグ×2点
  });

  test('CSVにヘッダと全行が含まれる', () {
    final csv = exporter.buildCsv(makeSession());
    final lines = csv.trim().split('\n');
    expect(lines.length, 3); // ヘッダ + 2点
    expect(lines.first, contains('timestamp'));
    expect(lines.first, contains('spm'));
  });

  test('セッションのJSON往復変換が一致する', () {
    final session = makeSession();
    final restored = Session.fromJson(session.toJson());
    expect(restored.id, session.id);
    expect(restored.points.length, session.points.length);
    expect(restored.summary.totalDistanceMeters,
        session.summary.totalDistanceMeters);
  });

  test('診断ZIPは診断カタログを含む必須ファイルと危険区域設定を含む', () {
    final base = makeSession();
    final session = base.copyWith(
      diagnosticMetadata: SessionDiagnosticMetadata(
        appVersion: '1.0.0',
        buildNumber: '1',
        gitCommitSha: '0123456789abcdef',
        buildTimestampUtc: '2026-08-13T00:00:00Z',
        buildFlavor: 'production',
        operatingSystemVersion: 'iOS 19.0',
        platform: 'ios',
        hazardProfileVersion: 3,
        hazardProfileSha256: 'abc',
        settingsSnapshot: const {
          'fixedObstacleCalibrations': [
            {
              'sourceId': 'bridge_1',
              'northMeters': 0.5,
              'eastMeters': -1.0,
            }
          ],
          'fixedObstacleProfile': {
            'version': 3,
            'sha256': 'abc',
            'sourceProfile': {
              'version': 3,
              'obstacles': [
                {
                  'id': 'bridge_1',
                  'points': [
                    {'lat': 36.067, 'lng': 140.2045},
                  ],
                },
              ],
            },
            'effectiveObstacles': [
              {
                'id': 'bridge_1',
                'sourceId': 'bridge_1',
                'points': [
                  {'lat': 36.0670045, 'lng': 140.204489},
                ],
              },
            ],
          },
        },
      ),
      alertEvents: [
        AlertDiagnosticEvent(
          t: base.startedAt,
          event: 'observation',
          alertId: 'raw-other-boat-id',
          detectorId: 'relative_boat_collision',
          category: 'other_boat',
          targetRef: 'persistent-boat-id',
          phase: 'alerting',
          isPrimary: true,
          riskLevel: 2,
          currentOverlap: false,
          confidence: 1,
          dataQuality: 'good',
        ),
      ],
    );

    final bytes = exporter.buildDiagnosticArchive(session);
    final archive = ZipDecoder().decodeBytes(bytes);
    final names = archive.files.map((file) => file.name).toSet();
    final files = exporter.buildDiagnosticFiles(session);

    expect(names, {
      'manifest.json',
      'diagnostic_event_catalog.json',
      'track.csv',
      'alerts.jsonl',
      'events.jsonl',
    });
    expect(files['manifest.json'], contains('fixedObstacleCalibrations'));
    final manifest =
        jsonDecode(files['manifest.json']!) as Map<String, dynamic>;
    expect(manifest['diagnosticPackageSchemaVersion'], 5);
    expect(manifest['diagnosticCatalogVersion'], 5);
    expect(manifest['app'], containsPair('gitCommitSha', '0123456789abcdef'));
    expect(manifest['app'], containsPair('buildFlavor', 'production'));
    expect(
      manifest['device'],
      containsPair('operatingSystemVersion', 'iOS 19.0'),
    );
    expect(files['diagnostic_event_catalog.json'],
        contains('H1_AUDIO_APP_COMPETITION'));
    expect(
      files['diagnostic_event_catalog.json'],
      contains('gps_dead_reckoning_prediction'),
    );
    expect(
      files['diagnostic_event_catalog.json'],
      contains('H7_IMU_FUSION_AND_STROKE_MOTION'),
    );
    expect(files['track.csv'], contains('raw_gnss_speed_mps'));
    final profile =
        Map<String, dynamic>.from(manifest['fixedObstacleProfile'] as Map);
    expect(profile['sha256'], 'abc');
    expect(
      profile['sourceProfile'],
      containsPair('version', 3),
    );
    expect(
      (profile['effectiveObstacles'] as List).single,
      containsPair('sourceId', 'bridge_1'),
    );
    expect(
      Map<String, dynamic>.from(manifest['settings'] as Map),
      isNot(contains('fixedObstacleProfile')),
    );
    expect(files['track.csv'], contains('gnss_accuracy_m'));
    expect(files['alerts.jsonl'], isNot(contains('persistent-boat-id')));
    expect(files['alerts.jsonl'], contains('boat-1'));
  });

  test('GPX共有は非空ファイル・MIME・共有元矩形を渡し結果を返す', () async {
    final temp = await Directory.systemTemp.createTemp('rowing-export-');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    ShareParams? captured;
    final service = GpxExportService(
      temporaryDirectoryProvider: () async => temp,
      share: (params) async {
        captured = params;
        return const ShareResult('saved', ShareResultStatus.success);
      },
    );
    const origin = Rect.fromLTWH(10, 20, 100, 48);

    final result = await service.shareAsGpx(
      makeSession(),
      sharePositionOrigin: origin,
    );

    expect(result.status, ShareResultStatus.success);
    expect(captured?.sharePositionOrigin, origin);
    expect(captured?.files, hasLength(1));
    expect(captured?.files?.single.mimeType, 'application/gpx+xml');
    expect(await captured!.files!.single.length(), greaterThan(0));
  });
}
