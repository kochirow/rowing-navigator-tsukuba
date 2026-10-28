import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/session_model.dart';
import 'package:rowing_navigator/services/diagnostic_bundle_service.dart';
import 'package:rowing_navigator/services/gpx_export_service.dart';
import 'package:share_plus/share_plus.dart';

Session _session(
  String id, {
  double movingSec = 20 * 60,
  double durationSec = 30 * 60,
  double distance = 3000,
  DateTime? sharedAt,
  int pointCount = 3,
  DateTime? startedAt,
}) {
  final start = startedAt ?? DateTime.utc(2026, 10, 1, 6);
  return Session(
    id: id,
    startedAt: start,
    endedAt: start.add(Duration(seconds: durationSec.round())),
    boatTypeName: '1x',
    seatPosLabel: 'ストローク',
    points: [
      for (var i = 0; i < pointCount; i++)
        TrackPoint(
          t: start.add(Duration(seconds: i)),
          lat: 36.07 + i * 0.00001,
          lng: 140.2 + (i * 7919 % 1000) * 0.0000001,
          speed: 3,
          heading: 0,
          safetyLevel: 'safe',
        ),
    ],
    summary: SessionSummary(
      totalDistanceMeters: distance,
      durationSec: durationSec,
      maxSpeed: 4,
      avgSpeed: 3,
      movingTimeSec: movingSec,
      splits: const [],
      pieces: const [],
      alertCounts: const {},
    ),
    diagnosticsSharedAt: sharedAt,
  );
}

void main() {
  group('まとめて送る対象', () {
    test('練習時間15分・距離2km ちょうどは入り、どちらかが足りなければ外れる', () {
      expect(
          isBulkLogExportTarget(_session('ok', movingSec: 900, distance: 2000)),
          isTrue);
      expect(
          isBulkLogExportTarget(
              _session('short', movingSec: 899, distance: 5000)),
          isFalse);
      expect(
          isBulkLogExportTarget(
              _session('near', movingSec: 3600, distance: 1999)),
          isFalse);
    });

    test('練習時間は記録の長さではなく艇が動いていた時間で数える', () {
      // 1時間の記録でも、動いていたのが10分なら対象外。
      expect(
          isBulkLogExportTarget(
              _session('idle', movingSec: 600, durationSec: 3600)),
          isFalse);
    });

    test('動いていた時間が無い古い記録は、記録の長さで代える', () {
      final old = _session('old', movingSec: 0, durationSec: 1800);
      expect(practiceSecOf(old), 1800);
      expect(isBulkLogExportTarget(old), isTrue);
    });

    test('送信済みは外れ、残りは古い順に並ぶ', () {
      final list = pendingBulkLogExports([
        _session('new', startedAt: DateTime.utc(2026, 10, 3)),
        _session('sent', sharedAt: DateTime.utc(2026, 10, 4)),
        _session('older', startedAt: DateTime.utc(2026, 10, 2)),
      ]);
      expect(list.map((s) => s.id), ['older', 'new']);
    });
  });

  group('ZIP', () {
    test('記録ごとのフォルダに単体ZIPと同じ5ファイルと bundle_manifest を入れる', () {
      final bundles = DiagnosticBundleService.buildBundles(
        [_session('a'), _session('b')],
        createdAt: DateTime(2026, 10, 28, 18, 2),
      );
      expect(bundles, hasLength(1));
      expect(bundles.single.sessionIds, ['a', 'b']);
      expect(bundles.single.fileName,
          'rowing_diagnostics_bundle_20261028-1802_2.zip');

      final archive = ZipDecoder().decodeBytes(bundles.single.bytes);
      final names = archive.files.map((f) => f.name).toSet();
      final single = GpxExportService().buildDiagnosticFiles(_session('a'));
      for (final id in ['a', 'b']) {
        for (final f in single.keys) {
          expect(names, contains('rowing_diagnostics_$id/$f'));
        }
      }
      final manifest = jsonDecode(utf8.decode(
              archive.findFile('bundle_manifest.json')!.content as List<int>))
          as Map<String, dynamic>;
      expect((manifest['sessions'] as List).length, 2);
      expect(manifest['privacy']['automaticUpload'], isFalse);
    });

    test('上限を超えると記録単位で複数のZIPに分ける', () {
      final sessions = [
        for (var i = 0; i < 3; i++) _session('s$i', pointCount: 4000)
      ];
      final one = DiagnosticBundleService.buildBundles([sessions.first],
          createdAt: DateTime(2026, 10, 28));
      // 1記録ぶん + 見出しの余裕しか入らない上限にする。
      final limit = one.single.bytes.length + 64 * 1024 + 10;
      final bundles = DiagnosticBundleService.buildBundles(sessions,
          createdAt: DateTime(2026, 10, 28), maxZipBytes: limit);
      expect(bundles, hasLength(3));
      expect(bundles.expand((b) => b.sessionIds), ['s0', 's1', 's2']);
      expect(bundles.first.fileName, endsWith('_part1of3.zip'));
      for (final b in bundles) {
        expect(b.bytes.length, lessThanOrEqualTo(limit));
      }
    });

    test('共有シートへ全部のZIPを起点付きで渡す', () async {
      final dir = await Directory.systemTemp.createTemp('bundle-share-');
      addTearDown(() => dir.delete(recursive: true));
      ShareParams? shared;
      final service = DiagnosticBundleService(
        temporaryDirectoryProvider: () async => dir,
        share: (params) async {
          shared = params;
          return const ShareResult('', ShareResultStatus.success);
        },
      );
      final bundles = DiagnosticBundleService.buildBundles([_session('a')],
          createdAt: DateTime(2026, 10, 28));
      await service.share(bundles,
          sharePositionOrigin: const Rect.fromLTWH(10, 10, 40, 40));
      expect(shared!.files, hasLength(1));
      expect(shared!.sharePositionOrigin, const Rect.fromLTWH(10, 10, 40, 40));
    });

    test('起点が無いときは共有せずに理由を返す', () async {
      final service = DiagnosticBundleService(
        temporaryDirectoryProvider: () async => Directory.systemTemp,
        share: (_) async => fail('共有してはいけない'),
      );
      final bundles = DiagnosticBundleService.buildBundles([_session('a')],
          createdAt: DateTime(2026, 10, 28));
      expect(() => service.share(bundles, sharePositionOrigin: Rect.zero),
          throwsA(isA<SessionExportException>()));
    });
  });

  test('送信済みと全体評価はJSONで往復し、古いJSONは未送信として読む', () {
    final sharedAt = DateTime.fromMillisecondsSinceEpoch(1790000000000);
    final s = _session('a', sharedAt: sharedAt)
        .copyWith(alertOverallRating: () => AlertOverallRating.tooMany.name);
    final restored = Session.fromJson(s.toJson());
    expect(restored.diagnosticsSharedAt, sharedAt);
    expect(restored.alertOverallRating, 'tooMany');

    final legacy = s.toJson()
      ..remove('diagnosticsSharedAt')
      ..remove('alertOverallRating');
    final old = Session.fromJson(legacy);
    expect(old.isDiagnosticsShared, isFalse);
    expect(old.alertOverallRating, isNull);

    // 「未送信に戻す」で null へ戻せる。
    expect(
        restored.copyWith(diagnosticsSharedAt: () => null).diagnosticsSharedAt,
        isNull);
  });
}
