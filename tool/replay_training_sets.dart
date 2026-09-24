// 記録画面のセット判定（lib/services/record/training_set_detector.dart）を実機ログで確かめる。
// 設計書 §7.0 の表（HTML試作の結果）と同じセット分けになるかを目で比べる。
//
//   flutter test tool/replay_training_sets.dart \
//     --dart-define=LOG_DIRS=/path/a,/path/b --dart-define=BOATS=r_4x,r_8p
//
// LOG_DIRS が無い場合はスキップする（CIでは走らない）。

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/record/boat_speed_estimator.dart';
import 'package:rowing_navigator/services/record/session_overview.dart';
import 'package:rowing_navigator/services/record/training_set_detector.dart';

import 'record_log_reader.dart';

const _dirs = String.fromEnvironment('LOG_DIRS');
const _boats = String.fromEnvironment('BOATS');

String fm(double s) {
  final n = s.round();
  final h = n ~/ 3600, m = (n % 3600) ~/ 60, ss = n % 60;
  return h > 0
      ? '$h:${m.toString().padLeft(2, '0')}:${ss.toString().padLeft(2, '0')}'
      : '$m:${ss.toString().padLeft(2, '0')}';
}

void main() {
  test('実機ログのセット分け', () {
    final dirs = _dirs.split(',');
    final boats = _boats.split(',');
    for (var k = 0; k < dirs.length; k++) {
      final boat = k < boats.length ? boats[k] : '';
      final est = const BoatSpeedEstimator()
          .estimate(readTrack(dirs[k]), boatTypeName: boat);
      final sets =
          const TrainingSetDetector().detect(est.track, boatTypeName: boat);
      final o = SessionOverview.from(est.track, sets);
      final lines = [
        for (final s in sets)
          '  ${s.index + 1}: ${s.intensity.label} ${fm(s.range.start)}-${fm(s.range.end)}'
              ' ${s.bouts.length}${s.intensity.unit} 平均${s.stats.paceSecPer500 == null ? '--' : fm(s.stats.paceSecPer500!)}'
              ' SR${s.stats.averageSpm?.round() ?? '-'} レスト${fm(s.restSec)}',
      ];
      // ignore: avoid_print
      print(
          '${dirs[k].split('/').last} ($boat) 距離${(est.track.totalDistance / 1000).toStringAsFixed(2)}km'
          ' 漕いでいた${fm(o.rowingSec)} 練習${fm(o.practiceSec)}\n${lines.join('\n')}');
      expect(sets, isNotEmpty);
    }
  }, skip: _dirs.isEmpty ? 'LOG_DIRS が無い' : false);
}
