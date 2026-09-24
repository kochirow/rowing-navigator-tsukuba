import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/record/replay_track.dart';
import 'package:rowing_navigator/services/record/session_overview.dart';
import 'package:rowing_navigator/services/record/training_set_detector.dart';

/// 区切りごとに艇速・SR・向きを決めて、1秒ごとの航跡を作る。
class Leg {
  final int seconds;
  final double speed;
  final double? spm;
  final double heading;
  const Leg(this.seconds, this.speed, this.spm, [this.heading = 0]);
}

ReplayTrack build(List<Leg> legs) {
  final t = <double>[], lat = <double>[], lng = <double>[];
  final hd = <double>[], v = <double>[], spm = <double?>[];
  var time = 0.0;
  for (final leg in legs) {
    for (var s = 0; s < leg.seconds; s++) {
      t.add(time);
      lat.add(36.08);
      lng.add(140.21);
      hd.add(leg.heading);
      v.add(leg.speed);
      spm.add(leg.spm);
      time += 1;
    }
  }
  return ReplayTrack(t: t, lat: lat, lng: lng, heading: hd, speed: v, spm: spm);
}

void main() {
  const detector = TrainingSetDetector();

  test('UT の往復はターンをはさんで1セット、すき間は「ターン」', () {
    final tr = build(const [
      Leg(60, 0, null),
      Leg(300, 4.0, 20, 0),
      // ターン: 止まりかけの間に向きが 0°→180° へ回る
      Leg(45, 0.3, null, 0),
      Leg(45, 0.3, null, 180),
      Leg(300, 4.0, 20, 180),
      Leg(45, 0.3, null, 180),
      Leg(45, 0.3, null, 0),
      Leg(300, 4.0, 20, 0),
      Leg(60, 0, null),
    ]);
    final sets = detector.detect(tr, boatTypeName: 'r_4x');
    expect(sets, hasLength(1));
    final s = sets.single;
    expect(s.intensity, TrainingIntensity.ut);
    expect(s.bouts, hasLength(3));
    expect(s.stats.averageSpm, closeTo(20, 0.5));
    final gap = ReplayRange(s.bouts[0].range.end, s.bouts[1].range.start);
    expect(detector.gapKind(tr, gap), GapKind.turn);
  });

  test('ハイレート×5をパドルでつなぐ → 1セット5本、パドルは平均に入らない', () {
    final legs = <Leg>[const Leg(30, 0, null)];
    for (var k = 0; k < 5; k++) {
      legs.add(const Leg(40, 5.0, 34));
      legs.add(const Leg(80, 2.3, 20));
    }
    legs.add(const Leg(30, 0, null));
    final tr = build(legs);
    final sets = detector.detect(tr, boatTypeName: 'r_4x');
    expect(sets, hasLength(1));
    final s = sets.single;
    expect(s.intensity, TrainingIntensity.highRate);
    expect(s.bouts, hasLength(5));
    expect(s.stats.paceSecPer500, closeTo(100, 3));
    expect(s.stats.averageSpm, closeTo(34, 0.5));
    expect(s.restSec, greaterThan(4 * 70));
    final gap = ReplayRange(s.bouts[0].range.end, s.bouts[1].range.start);
    expect(detector.gapKind(tr, gap), GapKind.paddle);
  });

  test('陸上で艇を運ぶ揺れ（止まっていてSR60）はハイレートにしない', () {
    final tr = build(const [Leg(300, 0, 60), Leg(300, 0.2, 58)]);
    expect(detector.detect(tr, boatTypeName: 'r_4x'), isEmpty);
  });

  test('5分を超えて空いたハイレートは別のセット', () {
    final tr = build(const [
      Leg(40, 5.0, 34),
      Leg(60, 0, null),
      Leg(40, 5.0, 34),
      Leg(400, 0, null),
      Leg(40, 5.0, 34),
    ]);
    final sets = detector.detect(tr, boatTypeName: 'r_4x');
    expect(sets.map((s) => s.bouts.length), [2, 1]);
    expect(
        sets.every((s) => s.intensity == TrainingIntensity.highRate), isTrue);
  });

  test('平均SR 24〜28 は AT', () {
    final tr =
        build(const [Leg(30, 0, null), Leg(400, 4.3, 26), Leg(30, 0, null)]);
    final sets = detector.detect(tr, boatTypeName: 'r_4x');
    expect(sets.single.intensity, TrainingIntensity.at);
  });

  test('ほとんど止まっていたすき間は「停止」', () {
    final tr = build(const [
      Leg(300, 4.0, 20),
      Leg(120, 0, null),
      Leg(300, 4.0, 20),
    ]);
    final s = detector.detect(tr, boatTypeName: 'r_4x').single;
    final gap = ReplayRange(s.bouts[0].range.end, s.bouts[1].range.start);
    expect(detector.gapKind(tr, gap), GapKind.stop);
  });

  test('全体サマリ: 漕いでいた時間=本・区間の合計、練習時間=動いていた時間', () {
    final tr = build(const [
      Leg(60, 0, null),
      Leg(300, 4.0, 20),
      Leg(120, 2.0, 18),
      Leg(40, 5.0, 34),
      Leg(60, 2.3, 20),
      Leg(40, 5.0, 34),
      Leg(60, 0, null),
    ]);
    final sets = detector.detect(tr, boatTypeName: 'r_4x');
    final o = SessionOverview.from(tr, sets);
    expect(
        o.rowingSec, closeTo(sets.fold(0.0, (a, s) => a + s.rowingSec), 1e-9));
    expect(o.practiceSec, closeTo(300 + 120 + 40 + 60 + 40, 2));
    expect(o.rowingByIntensity[TrainingIntensity.ut], greaterThan(250));
    expect(o.rowingByIntensity[TrainingIntensity.highRate], greaterThan(60));
    expect(o.otherMovingSec, greaterThan(0));
  });
}
