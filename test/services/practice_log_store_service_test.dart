import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/practice_log_model.dart';
import 'package:rowing_navigator/services/practice_log_store_service.dart';

void main() {
  late Directory docs;
  late PracticeLogStoreService store;
  final start = DateTime.utc(2026, 10, 1, 6);

  PracticeLog log(String id) => PracticeLog(
        id: id,
        teamId: 'team',
        recordedBy: 'observer',
        startedAt: start,
        endedAt: start.add(const Duration(minutes: 40)),
        isComplete: true,
        pointCount: 12,
        eventCount: 3,
      );

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('practice-log-store-');
    store =
        PracticeLogStoreService(documentsDirectoryProvider: () async => docs);
  });
  tearDown(() => docs.delete(recursive: true));

  test('送信済みの時刻は他の項目を変えずに保存され、一覧で読める', () async {
    await store.create(log('practice_20261001_060000'));
    final sharedAt = DateTime.fromMillisecondsSinceEpoch(1790000000000);
    await store.markDiagnosticsShared('practice_20261001_060000', sharedAt);

    final read = (await store.list()).single;
    expect(read.diagnosticsSharedAt, sharedAt);
    expect(read.isDiagnosticsShared, isTrue);
    expect(read.pointCount, 12);
    expect(read.eventCount, 3);
    expect(read.isComplete, isTrue);
    expect(read.endedAt, start.add(const Duration(minutes: 40)));
  });

  test('印の項目が無い古いmeta.jsonは未送信として読む', () async {
    await store.create(log('practice_20261001_060000'));
    final file =
        File('${docs.path}/practice_logs/practice_20261001_060000/meta.json');
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(json, isNot(contains('diagnosticsSharedAt')));
    expect((await store.list()).single.isDiagnosticsShared, isFalse);
  });

  test('無いログに印を付けても何も作らず、エラーにもしない', () async {
    await store.markDiagnosticsShared(
        'practice_20261001_060000', DateTime.utc(2026, 10, 2));
    expect(await store.list(), isEmpty);
  });

  test('copyWith は印を保ち、関数で渡すと消せる', () {
    final shared = log('practice_20261001_060000')
        .copyWith(diagnosticsSharedAt: () => DateTime.utc(2026, 10, 2));
    expect(shared.copyWith(pointCount: 1).isDiagnosticsShared, isTrue);
    expect(shared.copyWith(diagnosticsSharedAt: () => null).isDiagnosticsShared,
        isFalse);
  });
}
