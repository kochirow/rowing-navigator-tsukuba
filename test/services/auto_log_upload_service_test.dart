import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/practice_log_model.dart';
import 'package:rowing_navigator/models/session_model.dart';
import 'package:rowing_navigator/services/auto_log_upload_service.dart';
import 'package:rowing_navigator/services/diagnostic_bundle_service.dart';
import 'package:rowing_navigator/services/practice_log_store_service.dart';
import 'package:rowing_navigator/services/session_store_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Session _session(
  String id, {
  double durationSec = 30 * 60,
  bool complete = true,
  DateTime? sharedAt,
}) {
  final start = DateTime.utc(2026, 11, 10, 6);
  return Session(
    id: id,
    startedAt: start,
    endedAt: start.add(Duration(seconds: durationSec.round())),
    boatTypeName: '4+',
    seatPosLabel: 'ストローク',
    isComplete: complete,
    points: [
      for (var i = 0; i < 3; i++)
        TrackPoint(
          t: start.add(Duration(seconds: i)),
          lat: 36.07 + i * 0.00001,
          lng: 140.2,
          speed: 3,
          heading: 0,
          safetyLevel: 'safe',
        ),
    ],
    summary: SessionSummary(
      totalDistanceMeters: 500,
      durationSec: durationSec,
      maxSpeed: 4,
      avgSpeed: 3,
      movingTimeSec: durationSec,
      splits: const [],
      pieces: const [],
      alertCounts: const {},
    ),
    diagnosticsSharedAt: sharedAt,
  );
}

PracticeLog _practiceLog(String id, {int minutes = 20, DateTime? sharedAt}) {
  final start = DateTime.utc(2026, 11, 10, 6);
  return PracticeLog(
    id: id,
    livePointCount: 1,
    teamId: 'team',
    recordedBy: 'observer',
    startedAt: start,
    endedAt: start.add(Duration(minutes: minutes)),
    isComplete: true,
    diagnosticsSharedAt: sharedAt,
  );
}

class _FakePoster {
  final List<Map<String, Object?>> requests = [];
  LogUploadResponse Function(Map<String, Object?> body) respond =
      (_) => const LogUploadResponse.success();

  Future<LogUploadResponse> call(
      Uri endpoint, Map<String, Object?> body) async {
    requests.add(body);
    return respond(body);
  }
}

void main() {
  late Directory docs;
  late SessionStoreService sessions;
  late PracticeLogStoreService practiceLogs;
  late _FakePoster poster;
  String? idToken;

  AutoLogUploadService service(
          {String endpoint = 'https://example.test/exec'}) =>
      AutoLogUploadService(
        endpoint: endpoint,
        sessionStore: sessions,
        practiceLogStore: practiceLogs,
        poster: poster.call,
        idToken: () async => idToken,
        appCheckToken: () async => 'app-check',
        displayName: () async => '後藤',
        buildBundles: (s, p) async => DiagnosticBundleService.buildBundles(s,
            practiceLogs: p,
            createdAt: DateTime.utc(2026, 11, 10, 7),
            automaticUpload: true),
        now: () => DateTime.utc(2026, 11, 10, 8),
        // テストでは再送のタイマーを立てない。
        retryDelays: const [],
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    docs = await Directory.systemTemp.createTemp('auto_log_upload_test');
    sessions =
        SessionStoreService(documentsDirectoryProvider: () async => docs);
    practiceLogs =
        PracticeLogStoreService(documentsDirectoryProvider: () async => docs);
    poster = _FakePoster();
    idToken = 'id-token-for-test';
  });

  tearDown(() async {
    await docs.delete(recursive: true);
  });

  test('5分以上の航行を送り、送信済みの印を付けて列から外す', () async {
    await sessions.saveSession(_session('1794259577318'));
    final uploader = service();

    await uploader.enqueue(const AutoLogUploadTarget.session('1794259577318'));

    expect(poster.requests, hasLength(1));
    final body = poster.requests.single;
    expect(body['v'], 1);
    expect(body['idToken'], 'id-token-for-test');
    expect(body['appCheckToken'], 'app-check');
    expect(body['kind'], 'session');
    expect(body['recordId'], '1794259577318');
    expect(body['displayName'], '後藤');
    expect(body['boatType'], '4+');
    expect(body['startedAt'], '2026-11-10T06:00:00.000Z');
    expect(body['durationSec'], 1800);

    // ZIPは「まとめて送る」と同じ形で、自動で送った印が付く。
    final archive =
        ZipDecoder().decodeBytes(base64Decode(body['zipBase64'] as String));
    final names = archive.files.map((f) => f.name).toSet();
    expect(names, contains('bundle_manifest.json'));
    expect(names, contains('rowing_diagnostics_1794259577318/track.csv'));
    final manifest = jsonDecode(utf8.decode(archive.files
        .firstWhere((f) => f.name == 'bundle_manifest.json')
        .content as List<int>)) as Map<String, dynamic>;
    expect(manifest['privacy']['automaticUpload'], isTrue);

    final saved = await sessions.loadSession('1794259577318');
    expect(saved!.diagnosticsSharedAt!.toUtc(), DateTime.utc(2026, 11, 10, 8));
    expect(await uploader.pending(), isEmpty);
  });

  test('5分に満たない航行・未完了の記録は送らずに列から外す', () async {
    await sessions.saveSession(_session('short', durationSec: 4 * 60 + 59));
    await sessions.saveSession(_session('recording', complete: false));
    final uploader = service();

    await uploader.enqueue(const AutoLogUploadTarget.session('short'));
    await uploader.enqueue(const AutoLogUploadTarget.session('recording'));
    await uploader.enqueue(const AutoLogUploadTarget.session('missing'));

    expect(poster.requests, isEmpty);
    expect(await uploader.pending(), isEmpty);
    expect((await sessions.loadSession('short'))!.diagnosticsSharedAt, isNull);
  });

  test('送れなかった記録は列に残り、次に送れたら印が付く', () async {
    await sessions.saveSession(_session('a'));
    final uploader = service();
    poster.respond = (_) => const LogUploadResponse.failure('network');

    await uploader.enqueue(const AutoLogUploadTarget.session('a'));

    expect(await uploader.pending(), [const AutoLogUploadTarget.session('a')]);
    expect((await sessions.loadSession('a'))!.diagnosticsSharedAt, isNull);

    poster.respond = (_) => const LogUploadResponse.success();
    await uploader.drain();

    expect(await uploader.pending(), isEmpty);
    expect((await sessions.loadSession('a'))!.diagnosticsSharedAt, isNotNull);
  });

  test('ログインしていないときは送らずに待つ', () async {
    await sessions.saveSession(_session('a'));
    idToken = null;
    final uploader = service();

    await uploader.enqueue(const AutoLogUploadTarget.session('a'));

    expect(poster.requests, isEmpty);
    expect(await uploader.pending(), [const AutoLogUploadTarget.session('a')]);
  });

  test('送れなかった記録は列の最後へ回り、他の記録を止めない', () async {
    await sessions.saveSession(_session('bad'));
    await sessions.saveSession(_session('good'));
    SharedPreferences.setMockInitialValues({
      AutoLogUploadService.queueKey: ['s:bad', 's:good'],
    });
    final uploader = service();
    poster.respond = (body) => body['recordId'] == 'bad'
        ? const LogUploadResponse.failure('too_large')
        : const LogUploadResponse.success();

    await uploader.drain();
    expect(await uploader.pending(), [
      const AutoLogUploadTarget.session('good'),
      const AutoLogUploadTarget.session('bad'),
    ]);

    await uploader.drain();
    expect(
        (await sessions.loadSession('good'))!.diagnosticsSharedAt, isNotNull);
    expect(
        await uploader.pending(), [const AutoLogUploadTarget.session('bad')]);
  });

  test('送信済みの記録を送り直しても、最初に送った時刻を残す', () async {
    final first = DateTime.utc(2026, 11, 9);
    await sessions.saveSession(_session('a', sharedAt: first));
    final uploader = service();

    await uploader.enqueue(const AutoLogUploadTarget.session('a'));

    expect(poster.requests, hasLength(1));
    expect(
        (await sessions.loadSession('a'))!.diagnosticsSharedAt!.toUtc(), first);
  });

  test('監視ログを送り、meta に送信済みの印を付ける', () async {
    final log = _practiceLog('practice_20261110_150000');
    await practiceLogs.create(log);
    await practiceLogs.append(log.id, points: [
      PracticeLogPoint(
        t: log.startedAt,
        source: PracticeLogSource.live,
        boatId: 'b1',
        displayName: '一号艇',
        lat: 36.07,
        lng: 140.2,
        ageSec: 1,
      ),
    ]);
    final uploader = service();

    await uploader.enqueue(
        const AutoLogUploadTarget.practiceLog('practice_20261110_150000'));

    expect(poster.requests, hasLength(1));
    expect(poster.requests.single['kind'], 'practiceLog');
    expect(poster.requests.single['durationSec'], 1200);
    expect(poster.requests.single.containsKey('boatType'), isTrue);
    final saved = (await practiceLogs.list()).single;
    expect(saved.diagnosticsSharedAt!.toUtc(), DateTime.utc(2026, 11, 10, 8));
  });

  test('起動時に、送っていない5分以上の記録だけを拾って送る', () async {
    await sessions.saveSession(_session('new'));
    await sessions
        .saveSession(_session('sent', sharedAt: DateTime.utc(2026, 11)));
    await sessions.saveSession(_session('short', durationSec: 60));
    await practiceLogs.create(_practiceLog('practice_20261110_150000'));
    await practiceLogs
        .create(_practiceLog('practice_20261110_160000', minutes: 3));
    final uploader = service();

    await uploader.enqueueBacklog();

    expect(poster.requests.map((b) => b['recordId']).toSet(),
        {'new', 'practice_20261110_150000'});
    expect(await uploader.pending(), isEmpty);
  });

  test('受け口が未設定なら何もしない', () async {
    await sessions.saveSession(_session('a'));
    final uploader = service(endpoint: '');

    await uploader.enqueue(const AutoLogUploadTarget.session('a'));
    await uploader.enqueueBacklog();

    expect(uploader.enabled, isFalse);
    expect(poster.requests, isEmpty);
  });

  test('start していないときの送り直しの依頼は何もしない', () async {
    await sessions.saveSession(_session('a'));
    final uploader = service();

    await uploader.requestReupload(const AutoLogUploadTarget.session('a'));

    expect(poster.requests, isEmpty);
    expect(await uploader.pending(), isEmpty);
  });

  group('受け口の返事', () {
    test('ok:true だけを成功にする', () {
      expect(LogUploadResponse.parse(200, '{"ok":true}').ok, isTrue);
      final rejected =
          LogUploadResponse.parse(200, '{"ok":false,"error":"not_member"}');
      expect(rejected.ok, isFalse);
      expect(rejected.error, 'not_member');
      final html = LogUploadResponse.parse(200, '<html>sign in</html>');
      expect(html.ok, isFalse);
      expect(html.error, 'unexpected_response_200');
    });

    test('列のキーを読み書きできる', () {
      expect(AutoLogUploadTarget.fromKey('s:123'),
          const AutoLogUploadTarget.session('123'));
      expect(AutoLogUploadTarget.fromKey('p:practice_20261110_150000'),
          const AutoLogUploadTarget.practiceLog('practice_20261110_150000'));
      expect(AutoLogUploadTarget.fromKey('x:1'), isNull);
      expect(AutoLogUploadTarget.fromKey(''), isNull);
    });
  });

  test('POST の後の 302 をたどって結果を読む(Apps Script の返し方)', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    Map<String, dynamic>? received;
    server.listen((request) async {
      if (request.method == 'POST') {
        received = jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, '/result?id=1');
      } else {
        expect(request.uri.path, '/result');
        request.response
          ..headers.contentType = ContentType.json
          ..write('{"ok":true}');
      }
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    final response = await postLogUpload(
        Uri.parse('http://127.0.0.1:${server.port}/exec'), {'v': 1});

    expect(response.ok, isTrue);
    expect(received, {'v': 1});
  });
}
