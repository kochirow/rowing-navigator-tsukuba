import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/replay_alerts.dart';

const _captureBaseline = bool.fromEnvironment('CAPTURE_REPLAY_BASELINE');
const _captureBaselineOutput = String.fromEnvironment('REPLAY_BASELINE_OUT');
const _replayLogsRoot = '../実機テストログデータ';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('過去7ログの警告エピソードは桟橋外で減少しない', () async {
    final logs = Directory(_replayLogsRoot);
    if (!logs.existsSync()) {
      markTestSkipped('個人航跡を含む実機ログが作業ツリーにないためスキップ');
      return;
    }
    final sessionDirectories = _sessionDirectories(logs);
    if (sessionDirectories.isEmpty) {
      markTestSkipped('replay対象のセッションディレクトリが見つからないためスキップ');
      return;
    }
    if (_captureBaseline) {
      final captured = <String, dynamic>{};
      for (final directory in sessionDirectories) {
        final result = await replaySessionDirectory(directory);
        captured[_sessionDirectoryName(directory)] = {
          'sessionId': result.sessionId,
          'boatType': result.boatType,
          'episodeCountInsideMooring': result.episodeCountInsideMooring,
          'episodeCountOutsideMooring': result.episodeCountOutsideMooring,
        };
      }
      final snapshot = {
        'schemaVersion': 1,
        'sessions': captured,
      };
      final encoded = const JsonEncoder.withIndent('  ').convert(snapshot);
      if (_captureBaselineOutput.isNotEmpty) {
        File(_captureBaselineOutput).writeAsStringSync(encoded);
      }
      // ignore: avoid_print
      print(encoded);
      return;
    }
    final baselineFile = File('test/replay/baseline_2026-07-28.json');
    final baseline = Map<String, dynamic>.from(
      jsonDecode(baselineFile.readAsStringSync()) as Map,
    );
    final sessions = Map<String, dynamic>.from(baseline['sessions'] as Map);
    for (final entry in sessions.entries) {
      final directory = sessionDirectories.firstWhere(
        (candidate) => _sessionDirectoryName(candidate) == entry.key,
        orElse: () => throw StateError(
          'baselineのreplay対象が見つかりません: ${entry.key}',
        ),
      );
      final result = await replaySessionDirectory(directory);
      final expected = Map<String, dynamic>.from(entry.value as Map);
      final actual = result.toJson();
      // 差分は数値調整時のレビュー材料であり、通常の失敗条件ではない。
      // ignore: avoid_print
      print(_formatDiff(entry.key, expected, actual));

      // 桟橋内の意図した静音と、航行中の警告漏れを分ける。既存baseline
      // に領域別集計が無い版も、桟橋未導入時の全件=桟橋外として読む。
      final expectedOutside = Map<String, dynamic>.from(
        (expected['episodeCountOutsideMooring'] ?? expected['episodeCount'])
            as Map,
      );
      final actualOutside = result.episodeCountOutsideMooring;
      for (final outside in expectedOutside.entries) {
        expect(
          actualOutside[outside.key] ?? 0,
          greaterThanOrEqualTo((outside.value as num).toInt()),
          reason: '$entry.key: ${outside.key} episodes outside mooring area '
              'decreased from ${outside.value} to '
              '${actualOutside[outside.key] ?? 0}',
        );
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

List<Directory> _sessionDirectories(Directory root) => root
    .listSync(recursive: true)
    .whereType<Directory>()
    .where((directory) => directory.uri.pathSegments.any(
          (segment) => RegExp(r'^2026_07_\d{2}$').hasMatch(segment),
        ))
    .where((directory) => File('${directory.path}/manifest.json').existsSync())
    .toList(growable: false);

String _sessionDirectoryName(Directory directory) =>
    directory.uri.pathSegments.where((segment) => segment.isNotEmpty).last;

String _formatDiff(
  String session,
  Map<String, dynamic> baseline,
  Map<String, dynamic> actual,
) =>
    const JsonEncoder.withIndent('  ').convert({
      'session': session,
      'baseline': baseline,
      'actual': actual,
    });
