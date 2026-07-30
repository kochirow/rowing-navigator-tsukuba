import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/practice_log_model.dart';
import 'package:rowing_navigator/services/practice_log_export_service.dart';

final start = DateTime.utc(2026, 7, 28, 5);

PracticeLog logFor() => PracticeLog(
      id: 'practice_20260728_0500',
      teamId: 'team',
      recordedBy: 'observer-uid',
      startedAt: start,
      endedAt: start.add(const Duration(hours: 2)),
      isComplete: true,
    );

PracticeLogPoint livePoint({
  required String boatId,
  String? displayName,
  int seconds = 0,
  String? presentationState,
  int sequence = 1,
}) =>
    PracticeLogPoint(
      t: start.add(Duration(seconds: seconds)),
      source: PracticeLogSource.live,
      boatId: boatId,
      displayName: displayName,
      sessionId: 'session',
      sequence: sequence,
      lat: 36.07,
      lng: 140.2,
      speed: 3.5,
      course: 90,
      accuracy: 4,
      battery: 80,
      presentationState: presentationState,
      safetyRunMode: 'f',
      ageSec: 1.5,
    );

void main() {
  final service = PracticeLogExportService();

  test('警告状態をバンドとカテゴリの列へ分けて出す', () {
    final files = service.buildFiles(
      logFor(),
      [livePoint(boatId: 'a', displayName: '一号艇', presentationState: '2o')],
      const [],
    );
    final rows = files['tracks.csv']!.trim().split('\n');
    expect(rows.first.split(','),
        containsAllInOrder(['warn_band', 'warn_category', 'run_mode']));
    final columns = rows[1].split(',');
    final header = rows.first.split(',');
    expect(columns[header.indexOf('warn_band')], '2');
    expect(columns[header.indexOf('warn_category')], 'o');
    expect(columns[header.indexOf('boat_alias')], '一号艇');
  });

  test('表示名が重複しても艇ごとに別のエイリアスへ割り当てる', () {
    // 既定の「名前未設定」のまま出す艇が複数いるのは普通に起こる。
    // 同じ列名へ潰すと、事故検証で別の艇の航跡を1本に混ぜてしまう。
    final files = service.buildFiles(
      logFor(),
      [
        livePoint(boatId: 'a', displayName: '名前未設定'),
        livePoint(boatId: 'b', displayName: '名前未設定', seconds: 1),
      ],
      const [],
    );
    final manifest =
        jsonDecode(files['practice_manifest.json']!) as Map<String, dynamic>;
    final aliases = (manifest['boats'] as List)
        .map((boat) => (boat as Map)['alias'] as String)
        .toList();
    expect(aliases.toSet(), hasLength(2));
    expect(aliases, containsAll(['名前未設定', '名前未設定-2']));
  });

  test('匿名化すると表示名を出さない', () {
    final files = service.buildFiles(
      logFor(),
      [livePoint(boatId: 'a', displayName: '一号艇')],
      const [],
      anonymized: true,
    );
    expect(files['tracks.csv'], isNot(contains('一号艇')));
    expect(files['tracks.csv'], contains('boat-1'));
    final manifest =
        jsonDecode(files['practice_manifest.json']!) as Map<String, dynamic>;
    expect(manifest['anonymized'], isTrue);
  });

  test('欠測秒数をgapイベントから積算し、受信途絶は件数で併記する', () {
    final files = service.buildFiles(
      logFor(),
      [livePoint(boatId: 'a', displayName: '一号艇')],
      [
        PracticeLogEvent(
          t: start.add(const Duration(seconds: 30)),
          elapsedMs: 30000,
          type: 'gap',
          details: {
            'boatId': 'a',
            'from': start.add(const Duration(seconds: 20)).toIso8601String(),
            'to': start.add(const Duration(seconds: 30)).toIso8601String(),
          },
        ),
        PracticeLogEvent(
          t: start.add(const Duration(seconds: 60)),
          elapsedMs: 60000,
          type: 'boat_lost',
          details: {'boatId': 'a'},
        ),
      ],
    );
    final manifest =
        jsonDecode(files['practice_manifest.json']!) as Map<String, dynamic>;
    final boat = (manifest['boats'] as List).first as Map;
    expect(boat['gapCount'], 1);
    expect(boat['missingSeconds'], 10);
    expect(boat['lostCount'], 1);
  });

  test('警告状態を送れない版が混ざったことをmanifestへ残す', () {
    final without = service.buildFiles(
      logFor(),
      [livePoint(boatId: 'a', displayName: '一号艇')],
      const [],
    );
    final manifest =
        jsonDecode(without['practice_manifest.json']!) as Map<String, dynamic>;
    expect(
        (manifest['protocol'] as Map)['presentationStateAvailable'], isFalse);
    final boat = (manifest['boats'] as List).first as Map;
    expect(boat['capabilities'], isNot(contains('presentation_state')));
  });

  test('自動アップロードしないことをmanifestへ明記する', () {
    final files =
        service.buildFiles(logFor(), [livePoint(boatId: 'a')], const []);
    final manifest =
        jsonDecode(files['practice_manifest.json']!) as Map<String, dynamic>;
    expect((manifest['privacy'] as Map)['automaticUpload'], isFalse);
    expect((manifest['privacy'] as Map)['scope'], 'team_members_only');
  });
}
