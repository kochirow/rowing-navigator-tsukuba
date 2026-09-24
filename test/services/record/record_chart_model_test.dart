import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/record/record_chart_model.dart';
import 'package:rowing_navigator/services/record/replay_track.dart';

ReplayTrack constant(int seconds, double speed, {double? spm}) {
  final n = seconds + 1;
  return ReplayTrack(
    t: [for (var i = 0; i < n; i++) i.toDouble()],
    lat: List.filled(n, 36.08),
    lng: List.filled(n, 140.21),
    heading: List.filled(n, 0),
    speed: List.filled(n, speed),
    spm: List.filled(n, spm),
  );
}

void main() {
  group('ChartYScale', () {
    test('/500m は速い側2%〜最大40秒で、5秒刻みに外側へ丸める', () {
      final values = [
        for (var i = 0; i < 100; i++) 96.0 + i * 0.6
      ]; // 1:36〜2:35
      final s = ChartYScale.fromValues(values, ChartMetric.pace)!;
      expect(s.step, 5);
      expect(s.low % 5, 0);
      expect(s.high % 5, 0);
      expect(s.low, lessThanOrEqualTo(96.6));
      expect(s.high - s.low, lessThanOrEqualTo(45));
    });

    test('ばらつきが小さくても最小幅（/500m は6秒）を確保する', () {
      final s =
          ChartYScale.fromValues(List.filled(50, 120.0), ChartMetric.pace)!;
      expect(s.high - s.low, greaterThanOrEqualTo(6));
      expect(s.ticks.first, s.low);
      expect(s.ticks.last, s.high);
    });

    test('SR は2刻み、DPS は0.5m刻み', () {
      expect(
          ChartYScale.fromValues([for (var i = 0; i < 40; i++) 18.0 + i * 0.1],
                  ChartMetric.spm)!
              .step,
          2);
      expect(
          ChartYScale.fromValues([for (var i = 0; i < 40; i++) 10.0 + i * 0.05],
                  ChartMetric.dps)!
              .step,
          0.5);
    });

    test('値がなければ作らない', () {
      expect(ChartYScale.fromValues(const [], ChartMetric.pace), isNull);
    });
  });

  group('ChartLayout', () {
    final track = constant(600, 4.0);
    const ranges = [
      ReplayRange(0, 100),
      ReplayRange(200, 300),
      ReplayRange(400, 600)
    ];

    test('本の長さに比例して並び、間は固定幅のすき間', () {
      final l = ChartLayout.compute(
          track: track,
          ranges: ranges,
          axis: ChartXAxis.time,
          plotLeft: 40,
          plotWidth: 332,
          gap: 34);
      final s = l.segments;
      expect(s[0].x0, 40);
      expect(s[1].x0 - s[0].x1, closeTo(34, 1e-9));
      expect(s[2].width, closeTo(s[0].width * 2, 1e-9));
      expect(s.last.x1, closeTo(40 + 332, 1e-9));
    });

    test('時刻 → 画面位置 → 時刻 が往復で一致する（時間軸・距離軸）', () {
      for (final axis in ChartXAxis.values) {
        final l = ChartLayout.compute(
            track: track,
            ranges: ranges,
            axis: axis,
            plotLeft: 40,
            plotWidth: 332);
        for (final time in [10.0, 250.0, 555.0]) {
          final x = l.xOf(time)!;
          expect(l.timeAt(x), closeTo(time, 1e-6), reason: '$axis $time');
        }
        expect(l.xOf(150), isNull, reason: 'レストの時刻はどの区画にも入らない');
      }
    });

    test('すき間の位置は本として選ばれない', () {
      final l = ChartLayout.compute(
          track: track,
          ranges: ranges,
          axis: ChartXAxis.time,
          plotLeft: 40,
          plotWidth: 332);
      final gapX = (l.segments[0].x1 + l.segments[1].x0) / 2;
      expect(l.segmentAt(gapX), isNull);
      expect(l.segmentAt(l.segments[1].x0 + 1)!.range, ranges[1]);
    });

    test('拡大すると区画が広がり、表示範囲の外へはみ出す', () {
      final z = ChartZoom.none.scaledAround(0.5, 3);
      final l = ChartLayout.compute(
          track: track,
          ranges: const [ReplayRange(0, 600)],
          axis: ChartXAxis.time,
          plotLeft: 40,
          plotWidth: 300,
          zoom: z);
      expect(l.segments.single.width, closeTo(900, 1e-6));
      expect(l.segments.single.x0, lessThan(40));
      expect(l.timeAt(190), closeTo(300, 1e-6), reason: '画面の中央は記録の中央');
    });
  });

  group('ChartZoom', () {
    test('拡大は×25まで、縮小は元の大きさまで', () {
      var z = ChartZoom.none;
      for (var i = 0; i < 10; i++) {
        z = z.scaledAround(0.5, 2);
      }
      expect(z.factor, closeTo(25, 1e-6));
      expect(z.scaledAround(0.5, 0.001), ChartZoom.none);
    });

    test('移動は端で止まる', () {
      final z = ChartZoom.none.scaledAround(0, 4);
      expect(z.start, 0);
      expect(z.panned(-1).start, 0);
      final r = z.panned(100);
      expect(r.end, closeTo(1, 1e-12));
    });
  });

  test('横軸の目盛りは30px以上あくきりのよい値', () {
    expect(chartTickStep(42, 50, ChartXAxis.time), 30);
    expect(chartTickStep(600, 300, ChartXAxis.time), 60);
    expect(chartTickStep(1000, 300, ChartXAxis.distance), 100);
  });

  test('指標の値は練習の漕ぎのときだけ（/500m は艇速から）', () {
    final tr = constant(10, 4.0, spm: 20);
    expect(chartMetricValue(tr, 5, ChartMetric.pace), closeTo(125, 1e-9));
    expect(chartMetricValue(tr, 5, ChartMetric.spm), 20);
    expect(chartMetricValue(tr, 5, ChartMetric.dps), closeTo(12, 1e-9));
    expect(chartMetricValue(constant(10, 1.0), 5, ChartMetric.pace), isNull);
  });
}
