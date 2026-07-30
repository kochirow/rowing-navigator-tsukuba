import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/session_model.dart';
import 'package:rowing_navigator/services/session_analyzer_service.dart';
import 'package:rowing_navigator/services/session_store_service.dart';

void main() {
  late Directory documentsDirectory;
  late SessionStoreService store;

  setUp(() async {
    documentsDirectory =
        await Directory.systemTemp.createTemp('rowing-session-store-');
    store = SessionStoreService(
      documentsDirectoryProvider: () async => documentsDirectory,
    );
  });

  tearDown(() async {
    if (await documentsDirectory.exists()) {
      await documentsDirectory.delete(recursive: true);
    }
  });

  Session makeSession({
    required bool isComplete,
    int pointCount = 2,
  }) {
    final startedAt = DateTime.utc(2026, 7, 22, 6);
    final points = List.generate(
      pointCount,
      (index) => TrackPoint(
        t: startedAt.add(Duration(seconds: index)),
        lat: 36.067 + index * 0.00001,
        lng: 140.2045,
        speed: 2.0,
        heading: 0,
        safetyLevel: 'safe',
      ),
    );
    return Session(
      id: startedAt.millisecondsSinceEpoch.toString(),
      startedAt: startedAt,
      endedAt: points.last.t,
      boatTypeName: 'quad',
      seatPosLabel: 'bow',
      points: points,
      summary: SessionAnalyzerService().analyze(points),
      isComplete: isComplete,
    );
  }

  test('未完了checkpointを次回の一覧で回復できる', () async {
    await store.saveSession(makeSession(isComplete: false));

    final sessions = await store.listSessions();

    expect(sessions, hasLength(1));
    expect(sessions.single.isComplete, isFalse);
    expect(sessions.single.points, hasLength(2));
  });

  test('正常終了時は同一IDのcheckpointを完成版で置き換える', () async {
    await store.saveSession(makeSession(isComplete: false));
    await store.saveSession(makeSession(isComplete: true, pointCount: 3));

    final sessions = await store.listSessions();
    final sessionFiles = await Directory('${documentsDirectory.path}/sessions')
        .list()
        .where((entity) => entity is File)
        .toList();

    expect(sessions, hasLength(1));
    expect(sessions.single.isComplete, isTrue);
    expect(sessions.single.points, hasLength(3));
    expect(sessionFiles, hasLength(1));
    expect(sessionFiles.single.path, endsWith('.json'));
  });

  test('過去形式のJSONは完了済みとして読み込む', () {
    final json = makeSession(isComplete: true).toJson()
      ..remove('isComplete')
      ..remove('schemaVersion');

    final restored = Session.fromJson(json);

    expect(restored.isComplete, isTrue);
    expect(restored.schemaVersion, 1);
    expect(restored.alertEvents, isEmpty);
    expect(restored.diagnosticEvents, isEmpty);
  });

  test('診断イベントと警告評価をJSON往復して保持する', () async {
    final base = makeSession(isComplete: true);
    final session = base.copyWith(
      diagnosticMetadata: SessionDiagnosticMetadata(
        appVersion: '1.0.0',
        buildNumber: '1',
        platform: 'ios',
        hazardProfileVersion: 3,
        hazardProfileSha256: 'abc',
        settingsSnapshot: const {
          'dangerZoneOffsets': {
            'bridge': {'waterSideMeters': 5.0}
          }
        },
      ),
      alertEvents: [
        AlertDiagnosticEvent(
          t: base.startedAt,
          event: 'observation',
          alertId: 'bridge-1',
          detectorId: 'static_collision',
          category: 'bridge',
          phase: 'alerting',
          isPrimary: true,
          riskLevel: 2,
          currentOverlap: false,
          confidence: 1,
          dataQuality: 'good',
        ),
      ],
      diagnosticEvents: [
        SessionDiagnosticEvent(
          t: base.startedAt,
          type: 'orientation_changed',
          details: const {'orientation': 'landscape'},
        ),
      ],
      alertEpisodeRatings: const {'bridge-1@0': 'tooEarly'},
    );

    await store.saveSession(session);
    final restored = (await store.listSessions()).single;

    expect(restored.schemaVersion, Session.currentSchemaVersion);
    expect(restored.diagnosticMetadata?.hazardProfileVersion, 3);
    expect(restored.alertEvents.single.category, 'bridge');
    expect(
        restored.diagnosticEvents.single.details['orientation'], 'landscape');
    expect(restored.alertEpisodeRatings['bridge-1@0'], 'tooEarly');
  });
}
