import 'dart:math' as math;

import '../../models/session_model.dart';
import '../../services/record/boat_speed_estimator.dart';
import '../../services/record/range_analyzer.dart';
import '../../services/record/replay_track.dart';
import '../../services/record/session_overview.dart';
import '../../services/record/training_set_detector.dart';

/// 記録ひとつ分の解析結果。画面を開いたときに1回だけ作る（再生・操作中は作り直さない）。
class ReplayAnalysis {
  final Session session;
  final EstimatedReplay estimated;
  final List<TrainingSet> sets;
  final SessionOverview overview;
  final RangeAnalyzer analyzer;

  /// 各点が、どれかのセットの本・区間の中にあるか（地図・時間軸の色分けに使う）。
  final List<bool> inBout;

  /// ペースの色の範囲 [秒/500m]（本・区間の中の 5〜95 パーセンタイル）。
  final double paceFast;
  final double paceSlow;

  ReplayTrack get track => estimated.track;

  ReplayAnalysis._({
    required this.session,
    required this.estimated,
    required this.sets,
    required this.overview,
    required this.analyzer,
    required this.inBout,
    required this.paceFast,
    required this.paceSlow,
  });

  factory ReplayAnalysis.compute(Session session) {
    final est = const BoatSpeedEstimator()
        .estimate(session.points, boatTypeName: session.boatTypeName);
    final track = est.track;
    final sets = const TrainingSetDetector()
        .detect(track, boatTypeName: session.boatTypeName);
    final inBout = List<bool>.filled(track.length, false);
    final paces = <double>[];
    for (final s in sets) {
      for (final b in s.bouts) {
        for (var i = track.indexAt(b.range.start);
            i <= track.indexAt(b.range.end);
            i++) {
          inBout[i] = true;
          final v = track.speed[i];
          if (v > 0.5) paces.add(500 / v);
        }
      }
    }
    paces.sort();
    double q(double p) =>
        paces[(paces.length * p).floor().clamp(0, paces.length - 1)];
    return ReplayAnalysis._(
      session: session,
      estimated: est,
      sets: sets,
      overview: SessionOverview.from(track, sets),
      analyzer: RangeAnalyzer(track),
      inBout: inBout,
      paceFast: paces.isEmpty ? 100 : q(0.05),
      paceSlow: paces.isEmpty ? 160 : math.max(q(0.95), q(0.05) + 1),
    );
  }

  /// ペースの色の比率（0=遅い 〜 1=速い）。
  double paceRatio(double secPer500) =>
      1 - (secPer500 - paceFast) / (paceSlow - paceFast);

  TrainingSet? setAt(double time) {
    for (final s in sets) {
      if (s.range.contains(time)) return s;
    }
    return null;
  }

  TrainingBout? boutAt(double time) {
    for (final s in sets) {
      for (final b in s.bouts) {
        if (b.range.contains(time)) return b;
      }
    }
    return null;
  }

  /// 全セットの本・区間（最速区間を探す範囲）。
  List<ReplayRange> get allBoutRanges => [
        for (final s in sets)
          for (final b in s.bouts) b.range
      ];

  /// 本と本のすき間の中身。
  GapKind gapKind(ReplayRange gap) =>
      const TrainingSetDetector().gapKind(track, gap);
}
