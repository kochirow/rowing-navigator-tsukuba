import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/session_model.dart';
import 'package:rowing_navigator/screens/record_replay/replay_analysis.dart';
import 'package:rowing_navigator/screens/record_replay/replay_controller.dart';
import 'package:rowing_navigator/services/record/record_chart_model.dart';
import 'package:rowing_navigator/services/record/replay_track.dart';

/// UT 1区間（5分）のあと、ハイレート×3本をパドルでつなぐ練習。
Session practice() {
  final t0 = DateTime(2026, 8, 6, 6);
  final points = <TrackPoint>[];
  var y = 0.0, t = 0;
  void leg(int seconds, double v, double? spm) {
    for (var k = 0; k < seconds; k++) {
      y += v;
      final lat = 36.08 + y / 111320.0;
      points.add(TrackPoint(
        t: t0.add(Duration(seconds: t)),
        elapsedMs: t * 1000,
        lat: lat,
        lng: 140.21,
        speed: v,
        heading: 0,
        spm: spm,
        safetyLevel: 'safe',
        rawLat: lat,
        rawLng: 140.21,
        rawGnssSpeedMetersPerSecond: v,
        speedAccuracyMetersPerSecond: 0.5,
      ));
      t++;
    }
  }

  leg(30, 0, null);
  leg(300, 4.0, 20);
  leg(120, 0, null);
  for (var k = 0; k < 3; k++) {
    leg(40, 5.0, 34);
    leg(80, 2.3, 20);
  }
  leg(30, 0, null);
  return Session(
    id: 'p',
    startedAt: t0,
    endedAt: t0.add(Duration(seconds: t)),
    boatTypeName: 'r_4x',
    seatPosLabel: 'バウ',
    points: points,
    summary: SessionSummary(
      totalDistanceMeters: 0,
      durationSec: t.toDouble(),
      maxSpeed: 5,
      avgSpeed: 3,
      splits: const [],
      pieces: const [],
      alertCounts: const {},
    ),
  );
}

void main() {
  late ReplayController c;
  setUp(() => c = ReplayController(ReplayAnalysis.compute(practice())));
  tearDown(() => c.dispose());

  test('開いた直後は全体を選び、セットを見分けている', () {
    expect(c.isAll, isTrue);
    expect(c.analysis.sets.length, 2);
    expect(c.analysis.sets.last.bouts.length, 3);
  });

  test('時間軸を1回タップでセット、もう一度タップでその本', () {
    final hr = c.analysis.sets.last;
    final t = hr.bouts[1].range.start + 10;
    c.tapTimeline(t);
    expect(c.selectedSet, same(hr));
    c.tapTimeline(t);
    expect(c.selectedBout, same(hr.bouts[1]));
    expect(c.cursor, closeTo(t, 1e-9));
  });

  test('セットの統計は本の中だけ、グラフは本ごとの区画', () {
    final hr = c.analysis.sets.last;
    c.selectSet(hr);
    expect(c.selectionStats.averageSpm, closeTo(34, 1));
    expect(c.chartRanges.length, 3);
  });

  test('区間の微調整は端を動かし、最短2秒を保つ', () {
    c.select(const ReplayRange(100, 200));
    c.nudge(start: true, seconds: 30);
    expect(c.selection, const ReplayRange(130, 200));
    c.nudge(start: false, seconds: -1000);
    expect(c.selection.duration, closeTo(2, 1e-9));
  });

  test('再生位置を開始・終了にする', () {
    c.select(const ReplayRange(100, 200));
    c.seek(150);
    c.setStartAtCursor();
    expect(c.selection.start, 150);
    c.seek(180);
    c.setEndAtCursor();
    expect(c.selection, const ReplayRange(150, 180));
  });

  test('選択を変えるとグラフの拡大は元に戻る', () {
    c.setZoom(ChartZoom.none.scaledAround(0.5, 4));
    expect(c.zoom.isZoomed, isTrue);
    c.select(const ReplayRange(10, 50));
    expect(c.zoom.isZoomed, isFalse);
  });

  testWidgets('再生は選択区間の終わりで止まる', (tester) async {
    c.select(const ReplayRange(100, 130), cursorAt: 100);
    c.setSpeed(200);
    c.play();
    await tester.pump(const Duration(seconds: 2));
    expect(c.isPlaying, isFalse);
    expect(c.cursor, closeTo(130, 1e-9));
  });

  test('地図を寄せる要求は選択のたびに増え、微調整では増えない', () {
    final before = c.mapFitRequest;
    c.selectSet(c.analysis.sets.first);
    expect(c.mapFitRequest, before + 1);
    c.nudge(start: true, seconds: 1);
    expect(c.mapFitRequest, before + 1);
  });
}
