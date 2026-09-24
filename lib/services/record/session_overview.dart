import 'dart:math' as math;

import '../../config/record_replay_config.dart';
import 'replay_track.dart';
import 'training_set_detector.dart';

/// 練習全体の時間の内訳（「全体」を選んだときのサマリ）。表示専用。
///
/// - 漕いでいた時間: 各セットの本・区間の合計（練習の強度で漕いだ時間）
/// - 練習時間: 艇が動いていた時間の合計（パドル・アップを含む）
class SessionOverview {
  final double rowingSec;
  final double practiceSec;
  final double stoppedSec;
  final Map<TrainingIntensity, double> rowingByIntensity;

  /// 記録の長さ [秒]。
  final double recordSec;

  const SessionOverview({
    required this.rowingSec,
    required this.practiceSec,
    required this.stoppedSec,
    required this.rowingByIntensity,
    required this.recordSec,
  });

  /// 動いていたが、どのセットにも入らない時間（パドル・アップ・移動）[秒]。
  double get otherMovingSec => math.max(0, practiceSec - rowingSec);

  factory SessionOverview.from(ReplayTrack track, List<TrainingSet> sets) {
    var moving = 0.0, stopped = 0.0;
    for (var i = 1; i < track.length; i++) {
      final dt =
          math.min(replayMaxIntegrationStepSec, track.t[i] - track.t[i - 1]);
      if (dt <= 0) continue;
      if (track.speed[i] >= replayMovingSpeedMps) {
        moving += dt;
      } else {
        stopped += dt;
      }
    }
    final by = {for (final k in TrainingIntensity.values) k: 0.0};
    for (final s in sets) {
      by[s.intensity] = by[s.intensity]! + s.rowingSec;
    }
    return SessionOverview(
      rowingSec: by.values.fold(0.0, (a, b) => a + b),
      practiceSec: moving,
      stoppedSec: stopped,
      rowingByIntensity: Map.unmodifiable(by),
      recordSec: track.duration,
    );
  }
}
