import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/replay_alerts.dart';

const _captureBaseline = bool.fromEnvironment('CAPTURE_REPLAY_BASELINE');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('2026-07-28 実機ログの警告エピソードは激変しない', () async {
    final logs = Directory('../実機テストログデータ/2026_07_28');
    if (!logs.existsSync()) {
      markTestSkipped('個人航跡を含む実機ログが作業ツリーにないためスキップ');
      return;
    }
    if (_captureBaseline) {
      final captured = <String, dynamic>{};
      for (final directory in logs.listSync().whereType<Directory>()) {
        final manifest = File('${directory.path}/manifest.json');
        if (!manifest.existsSync()) continue;
        final result = await replaySessionDirectory(directory);
        captured[directory.uri.pathSegments
            .where((segment) => segment.isNotEmpty)
            .last] = result.toJson();
      }
      // `dart run` cannot load this Flutter plugin graph on the VM in some
      // local SDKs, so this explicit Flutter-test route is also available for
      // writing the checked-in snapshot. It touches no application logic.
      // ignore: avoid_print
      print(const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': 1,
        'sessions': captured,
      }));
      return;
    }
    final baselineFile = File('test/replay/baseline_2026-07-28.json');
    final baseline = Map<String, dynamic>.from(
      jsonDecode(baselineFile.readAsStringSync()) as Map,
    );
    final sessions = Map<String, dynamic>.from(baseline['sessions'] as Map);
    for (final entry in sessions.entries) {
      final result = await replaySessionDirectory(
        Directory('${logs.path}/${entry.key}'),
      );
      final expected = Map<String, dynamic>.from(entry.value as Map);
      final actual = result.toJson();
      // 差分は数値調整時のレビュー材料であり、通常の失敗条件ではない。
      // ignore: avoid_print
      print(_formatDiff(entry.key, expected, actual));

      final baselineEpisodes = _episodeTotal(expected['episodeCount']);
      final actualEpisodes = result.episodeTotal;
      expect(
        actualEpisodes <= baselineEpisodes * 2 &&
            actualEpisodes * 2 >= baselineEpisodes,
        isTrue,
        reason: '$entry.key: warning episodes changed from '
            '$baselineEpisodes to $actualEpisodes (more than 2x)',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

int _episodeTotal(Object? raw) {
  final counts = Map<String, dynamic>.from(raw as Map);
  return counts.values.fold<int>(
    0,
    (total, value) => total + (value as num).toInt(),
  );
}

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
