import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/session_model.dart';
import 'package:rowing_navigator/services/record/range_analyzer.dart';
import 'package:rowing_navigator/services/record/replay_track.dart';
import 'package:rowing_navigator/services/session_analyzer_service.dart';

/// 1秒ごと・北向きに進む航跡。[speedAt] で各秒の艇速を決める。
ReplayTrack track(int seconds, double Function(int) speedAt,
    {double? Function(int)? spmAt}) {
  final t = <double>[], lat = <double>[], lng = <double>[];
  final hd = <double>[], v = <double>[], spm = <double?>[];
  var y = 36.07;
  for (var i = 0; i <= seconds; i++) {
    final s = speedAt(i);
    if (i > 0) y += s / 111320.0;
    t.add(i.toDouble());
    lat.add(y);
    lng.add(140.2);
    hd.add(0);
    v.add(s);
    spm.add(spmAt?.call(i));
  }
  return ReplayTrack(t: t, lat: lat, lng: lng, heading: hd, speed: v, spm: spm);
}

void main() {
  group('ReplayTrack', () {
    test('距離は艇速の時間積分で、止まっている間は増えない', () {
      final tr = track(20, (i) => i <= 10 ? 4.0 : 0.2);
      expect(tr.distanceAt(10), closeTo(40, 1e-9));
      expect(tr.distanceAt(20), closeTo(tr.distanceAt(11), 1e-9));
    });

    test('時刻の途中は前後の点で補間する', () {
      final tr = track(10, (_) => 4.0);
      expect(tr.distanceAt(2.5), closeTo(10, 1e-9));
      final p = tr.positionAt(2.5);
      expect(p.lat, closeTo((tr.lat[2] + tr.lat[3]) / 2, 1e-12));
    });

    test('範囲外の時刻は端に丸める', () {
      final tr = track(10, (_) => 4.0);
      expect(tr.indexAt(-5), 0);
      expect(tr.indexAt(99), 10);
      expect(tr.distanceAt(99), tr.totalDistance);
    });

    test('距離から時刻を逆に引ける', () {
      final tr = track(60, (_) => 5.0);
      expect(tr.timeAtDistance(125, 0, 60), closeTo(25, 1e-9));
      expect(tr.timeAtDistance(9999, 0, 60), isNull);
    });

    test('1回の積算は10秒までに切る（記録の欠けを長い漕行にしない）', () {
      final tr = ReplayTrack(
        t: [0, 60],
        lat: [36.0, 36.001],
        lng: [140.0, 140.0],
        heading: [0, 0],
        speed: [4, 4],
        spm: [null, null],
      );
      expect(tr.totalDistance, closeTo(40, 1e-9));
    });

    test('配列の長さがそろわなければ作らない', () {
      expect(
        () => ReplayTrack(
            t: [0, 1],
            lat: [0],
            lng: [0, 0],
            heading: [0, 0],
            speed: [0, 0],
            spm: [null, null]),
        throwsArgumentError,
      );
    });

    test('DPSは練習の漕ぎでSRがあるときだけ艇速から作る', () {
      final tr = track(3, (i) => i == 3 ? 1.0 : 4.0, spmAt: (_) => 20);
      expect(tr.dpsAt(1), closeTo(12, 1e-9));
      expect(tr.dpsAt(3), isNull);
    });
  });

  group('RangeAnalyzer', () {
    test('平均 /500m は動いていた時間から出し、止まっていた時間は分けて数える', () {
      final tr = track(100, (i) => i <= 50 ? 5.0 : 0.1);
      final st = RangeAnalyzer(tr).stats(const ReplayRange(0, 100));
      expect(st.movingSec, closeTo(50, 1e-9));
      expect(st.stoppedSec, closeTo(50, 1e-9));
      // 切り替わりの1区間は台形で積分するので、約2m多く数える。
      expect(st.paceSecPer500, closeTo(100, 1.5));
    });

    test('SRとDPSは練習の漕ぎの間だけの時間平均', () {
      final tr = track(40, (i) => i <= 20 ? 4.0 : 1.5,
          spmAt: (i) => i <= 20 ? 20 : 16);
      final st = RangeAnalyzer(tr).stats(const ReplayRange(0, 40));
      expect(st.averageSpm, closeTo(20, 1e-9));
      expect(st.averageDps, closeTo(12, 1e-9));
    });

    test('複数区間の合計は、それぞれの距離・時間・重みの和', () {
      final tr = track(100, (i) => i < 50 ? 4.0 : 5.0, spmAt: (_) => 24);
      final a = RangeAnalyzer(tr);
      final c = a.combined(const [ReplayRange(0, 20), ReplayRange(60, 80)]);
      expect(c.distance, closeTo(4.0 * 20 + 5.0 * 20, 1e-9));
      expect(c.duration, 40);
      expect(c.paceSecPer500, closeTo(40 * 500 / 180, 1e-9));
    });

    test('250mラップは区間の中で数え、端数を明記する', () {
      final tr = track(200, (_) => 5.0);
      final laps = RangeAnalyzer(tr).laps(const ReplayRange(0, 130));
      expect(laps.length, 3);
      expect(laps[0].range.duration, closeTo(50, 1e-9));
      expect(laps.last.isPartial, isTrue);
      expect(laps.last.toMeters, closeTo(650, 1e-9));
    });

    test('最速区間は総当たりと同じ答えになる', () {
      final rnd = math.Random(7);
      final speeds = List.generate(301, (_) => 3.5 + rnd.nextDouble() * 1.5);
      final tr = track(300, (i) => speeds[i]);
      final got = RangeAnalyzer(tr).fastest(500, const [ReplayRange(0, 300)])!;
      var bestDur = double.infinity;
      for (var i = 0; i <= 300; i++) {
        final end = tr.timeAtDistance(tr.cumulativeDistance[i] + 500, i, 300);
        if (end != null && end - i < bestDur) bestDur = end - i;
      }
      expect(got.duration, closeTo(bestDur, 1e-9));
    });

    test('一定速で漕いだ記録では、既存の解析と距離・時間が1%以内で一致する', () {
      final tr = track(600, (_) => 4.2);
      final t0 = DateTime(2026, 9, 24, 6);
      final points = [
        for (var i = 0; i < tr.length; i++)
          TrackPoint(
            t: t0.add(Duration(seconds: i)),
            lat: tr.lat[i],
            lng: tr.lng[i],
            speed: tr.speed[i],
            heading: 0,
            safetyLevel: 'safe',
          ),
      ];
      final legacy =
          SessionAnalyzerService().analyze(points, boatTypeName: 'r_4x');
      final st = RangeAnalyzer(tr).stats(ReplayRange(0, tr.duration));
      expect(
          st.distance,
          closeTo(
              legacy.totalDistanceMeters, legacy.totalDistanceMeters * 0.01));
      expect(st.duration, closeTo(legacy.durationSec, 1e-9));
    });

    test('最速区間は渡した区間をまたがない', () {
      final tr = track(200, (i) => i < 100 ? 5.0 : 0.1);
      final got = RangeAnalyzer(tr)
          .fastest(1000, const [ReplayRange(0, 100), ReplayRange(100, 200)]);
      expect(got, isNull);
    });
  });
}
