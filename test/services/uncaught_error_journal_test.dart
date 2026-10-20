import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/uncaught_error_journal.dart';

void main() {
  late Directory directory;
  late File file;
  // 裏で進むファイル書き込みが終わる前にディレクトリを消すと、
  // 環境によって「空でない」で失敗する。片付けの前に全部待つ。
  final created = <UncaughtErrorJournal>[];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('uncaught_journal');
    file = File('${directory.path}/uncaught_errors.jsonl');
  });

  tearDown(() async {
    for (final journal in created) {
      await journal.flushForTest();
    }
    created.clear();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  UncaughtErrorJournal journal({int maxUnreported = 50}) {
    final subject = UncaughtErrorJournal(
      fileProvider: () async => file,
      maxUnreported: maxUnreported,
    );
    created.add(subject);
    return subject;
  }

  test('記録した例外を取り出せ、取り出すと空になる', () async {
    final subject = journal();
    var notified = 0;
    final subscription = subject.changes.listen((_) => notified += 1);
    subject.record(StateError('boom'), StackTrace.current, source: 'flutter');
    await subject.flushForTest();
    await Future<void>.delayed(Duration.zero);

    final drained = subject.drainUnreported();
    expect(drained, hasLength(1));
    expect(drained.single.errorType, 'StateError');
    expect(drained.single.message, contains('boom'));
    expect(drained.single.source, 'flutter');
    expect(drained.single.previousRun, isFalse);
    expect(drained.single.stackTop, isNotNull);
    expect(subject.drainUnreported(), isEmpty);
    expect(notified, 1);
    await subscription.cancel();
  });

  test('報告前に終わった起動の例外は、次の起動で前回分として出る', () async {
    final firstRun = journal();
    firstRun.record(StateError('before kill'), null, source: 'platform');
    await firstRun.flushForTest();
    // 航行せずに終わった(drainしていない)。

    final secondRun = journal();
    await secondRun.loadPreviousRun();
    final drained = secondRun.drainUnreported();
    expect(drained, hasLength(1));
    expect(drained.single.previousRun, isTrue);
    expect(drained.single.message, contains('before kill'));
    await secondRun.flushForTest();

    // 書き出した分はファイルから消え、3回目の起動では出ない。
    final thirdRun = journal();
    await thirdRun.loadPreviousRun();
    expect(thirdRun.drainUnreported(), isEmpty);
  });

  test('取り出した後に起きた例外は、ファイルの消去で失われない', () async {
    final subject = journal();
    subject.record(StateError('first'), null, source: 'flutter');
    subject.drainUnreported();
    subject.record(StateError('second'), null, source: 'flutter');
    await subject.flushForTest();

    final next = journal();
    await next.loadPreviousRun();
    final messages = next.drainUnreported().map((r) => r.message).toList();
    expect(messages, [contains('second')]);
  });

  test('長い文面は切り詰め、溢れた件数を数える', () async {
    final subject = journal(maxUnreported: 2);
    final longMessage = 'x' * 1000;
    for (var i = 0; i < 3; i++) {
      subject.record(Exception(longMessage), null, source: 'flutter');
    }
    await subject.flushForTest();
    final drained = subject.drainUnreported();
    expect(drained, hasLength(2));
    expect(subject.droppedCount, 1);
    expect(
      drained.first.message.length,
      lessThanOrEqualTo(UncaughtErrorRecord.maxMessageLength + 1),
    );
  });

  test('ファイルが使えなくても記録・取り出しは続く', () async {
    final subject = UncaughtErrorJournal(
      fileProvider: () async => throw const FileSystemException('denied'),
    );
    subject.record(StateError('no disk'), null, source: 'flutter');
    await subject.flushForTest();
    await subject.loadPreviousRun();
    expect(subject.drainUnreported(), hasLength(1));
  });

  test('壊れた行は読み飛ばす', () async {
    await file.writeAsString('not json\n{"at":"x"}\n');
    final subject = journal();
    await subject.loadPreviousRun();
    expect(subject.drainUnreported(), isEmpty);
  });

  test('ハンドラを差し込んでも既存のハンドラと戻り値を保つ', () {
    final originalFlutter = FlutterError.onError;
    final originalPlatform = PlatformDispatcher.instance.onError;
    addTearDown(() {
      FlutterError.onError = originalFlutter;
      PlatformDispatcher.instance.onError = originalPlatform;
    });

    var previousFlutterCalls = 0;
    var previousPlatformCalls = 0;
    FlutterError.onError = (_) => previousFlutterCalls += 1;
    PlatformDispatcher.instance.onError = (_, __) {
      previousPlatformCalls += 1;
      return false;
    };

    final subject = journal();
    installUncaughtErrorHandlers(subject);
    FlutterError.onError!(FlutterErrorDetails(exception: StateError('ui')));
    final handled = PlatformDispatcher.instance.onError!(
      StateError('async'),
      StackTrace.empty,
    );

    expect(previousFlutterCalls, 1);
    expect(previousPlatformCalls, 1);
    expect(handled, isFalse);
    expect(
      subject.drainUnreported().map((r) => r.source),
      ['flutter', 'platform'],
    );
  });

  test('アカウントとデータの削除で、未報告の記録とファイルを消す', () async {
    final subject = journal();
    subject.record(StateError('private'), null, source: 'flutter');
    await subject.clearAll();
    expect(subject.drainUnreported(), isEmpty);
    final next = journal();
    await next.loadPreviousRun();
    expect(next.drainUnreported(), isEmpty);
  });
}
