import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/services/continuous_collision_service.dart';

/// [ContinuousCollisionService] が内部で使う局所平面と同じ換算で、
/// メートル指定の点を緯度経度へ戻す。往復で誤差が出ないよう定数を揃える。
const _earthRadiusMeters = 6378137.0;
const _originLatitude = 36.08;
const _originLongitude = 140.12;
final _origin = LatLng(_originLatitude, _originLongitude);

LatLng at(double east, double north) => LatLng(
      _originLatitude + north * 180 / (math.pi * _earthRadiusMeters),
      _originLongitude +
          east *
              180 /
              (math.pi *
                  _earthRadiusMeters *
                  math.cos(_originLatitude * math.pi / 180)),
    );

/// 中心 ([east], [north])、一辺 2×[halfSize] の正方形。
List<LatLng> square(double east, double north, double halfSize) => [
      at(east - halfSize, north - halfSize),
      at(east + halfSize, north - halfSize),
      at(east + halfSize, north + halfSize),
      at(east - halfSize, north + halfSize),
    ];

void main() {
  final service = ContinuousCollisionService();

  // 自艇領域: 一辺4m(半幅2m)の正方形、中心 (0,0)。真北へ 5m/s。
  // 危険区域はすべて半幅3mにする。自艇と辺が**共線にならない**寸法を選ぶ
  // 理由は、最後の group「既知の縮退」を参照。
  final moving = square(0, 0, 2);
  const northSpeed = 5.0;

  ContinuousIntersection sweepNorth(
    List<LatLng> staticPolygon, {
    double horizonSeconds = 10,
    double inflateMeters = 0,
    double speed = northSpeed,
  }) =>
      service.sweepAgainstStatic(
        movingPolygon: moving,
        staticPolygon: staticPolygon,
        origin: _origin,
        velocityEastMetersPerSecond: 0,
        velocityNorthMetersPerSecond: speed,
        horizonSeconds: horizonSeconds,
        inflateMeters: inflateMeters,
      );

  group('現在の重なり', () {
    test('すでに重なっているなら currentOverlap かつ侵入時刻0', () {
      final result = sweepNorth(square(1, 0, 3));

      expect(result.intersects, isTrue);
      expect(result.currentOverlap, isTrue);
      expect(result.firstEntryTimeSeconds, 0);
      expect(result.minimumSeparationMeters, 0);
    });

    test('辺が接するだけでも重なりとして扱う(境界は含む側=安全側)', () {
      // 自艇の前縁 +2m と、区域の後縁 +2m がちょうど一致する配置。
      final result = sweepNorth(square(1, 5, 3));

      expect(result.intersects, isTrue);
      expect(result.currentOverlap, isTrue);
      expect(result.firstEntryTimeSeconds, 0);
    });
  });

  group('予測地平の境界', () {
    // 100m 先の区域。自艇の前縁 +2m、区域の手前の縁 +97m。
    // 5m/s なので侵入は (97 − 2) / 5 = 19.0 秒、退出は (103 + 2) / 5 = 21.0 秒。
    final farObstacle = square(0, 100, 3);

    test('地平の外で初めて重なる場合は検知しない', () {
      final result = sweepNorth(farObstacle, horizonSeconds: 10);

      expect(result.intersects, isFalse);
      expect(result.currentOverlap, isFalse);
      expect(result.firstEntryTimeSeconds, isNull);
      // 10秒で 50m 進んでも、掃引の先端 +52m から区域まで 45m 残る。
      expect(result.minimumSeparationMeters, closeTo(45.0, 0.01));
    });

    test('地平を伸ばせば同じ配置を検知し、侵入時刻は幾何どおり', () {
      final result = sweepNorth(farObstacle, horizonSeconds: 25);

      expect(result.intersects, isTrue);
      expect(result.currentOverlap, isFalse);
      expect(result.firstEntryTimeSeconds, closeTo(19.0, 1e-6));
      expect(result.firstExitTimeSeconds, closeTo(21.0, 1e-6));
    });

    test('侵入時刻ちょうどが地平でも検知する(取りこぼさない)', () {
      // 「予測が届かない先では音が鳴らない」= 提示バンドの上限(10秒)を
      // 予測地平と一致させる不変条件の土台。ここが排他的だと
      // 「ちょうど地平の脅威」が消える。
      final result = sweepNorth(farObstacle, horizonSeconds: 19.0);

      expect(result.intersects, isTrue);
      expect(result.firstEntryTimeSeconds, closeTo(19.0, 1e-6));
    });

    test('地平を僅かに下回れば検知しない', () {
      final result = sweepNorth(farObstacle, horizonSeconds: 18.9);

      expect(result.intersects, isFalse);
    });
  });

  group('最接近距離(すれ違い)', () {
    // 東へ 10m ずれた区域。自艇の右縁 +2m、区域の左縁 +7m なので最接近は 5.0m。
    final passing = square(10, 50, 3);

    test('すれ違うだけなら検知せず、最接近距離が幾何と一致する', () {
      final result = sweepNorth(passing, horizonSeconds: 20);

      expect(result.intersects, isFalse);
      // `nearMissSeparationMeters`(2.0m)判定の土台になる値。
      expect(result.minimumSeparationMeters, closeTo(5.0, 0.01));
    });

    test('最接近距離は inflateMeters のぶんだけ縮む', () {
      final result =
          sweepNorth(passing, horizonSeconds: 20, inflateMeters: 1.5);

      expect(result.intersects, isFalse);
      expect(result.minimumSeparationMeters, closeTo(3.5, 0.01));
    });

    test('最接近距離は負にならない', () {
      final result = sweepNorth(passing, horizonSeconds: 20, inflateMeters: 20);

      expect(result.minimumSeparationMeters, 0);
    });
  });

  group('inflateMeters の単調性', () {
    final farObstacle = square(0, 100, 3);

    test('広げるほど侵入時刻が早まる', () {
      var previousEntry = double.infinity;
      for (final inflate in [0.0, 2.0, 4.0, 6.0, 8.0]) {
        final result = sweepNorth(
          farObstacle,
          horizonSeconds: 25,
          inflateMeters: inflate,
        );
        expect(result.intersects, isTrue, reason: 'inflate=$inflate');
        final entry = result.firstEntryTimeSeconds!;
        // 幾何どおり inflate/speed だけ早まる。
        expect(entry, closeTo(19.0 - inflate / northSpeed, 1e-6));
        expect(entry, lessThan(previousEntry), reason: 'inflate=$inflate');
        previousEntry = entry;
      }
    });

    test('広げれば、検知しなかった配置が地平内に入る', () {
      expect(sweepNorth(farObstacle, horizonSeconds: 10).intersects, isFalse);
      // 侵入 (97 − 50 − 2) / 5 = 9.0 秒 < 10 秒。
      final inflated =
          sweepNorth(farObstacle, horizonSeconds: 10, inflateMeters: 50);
      expect(inflated.intersects, isTrue);
      expect(inflated.firstEntryTimeSeconds, closeTo(9.0, 1e-6));
    });
  });

  group('相対速度ゼロ(並走・停止)', () {
    test('離れたまま止まっていれば検知せず、最接近距離を返す', () {
      final result = sweepNorth(square(10, 0, 3), speed: 0);

      expect(result.intersects, isFalse);
      expect(result.minimumSeparationMeters, closeTo(5.0, 0.01));
    });

    test('重なったまま止まっていれば地平いっぱい重なり続ける', () {
      final result = sweepNorth(square(1, 0, 3), speed: 0);

      expect(result.intersects, isTrue);
      expect(result.currentOverlap, isTrue);
      expect(result.firstEntryTimeSeconds, 0);
      expect(result.firstExitTimeSeconds, closeTo(10.0, 1e-9));
    });

    test('速度も地平も0の縮退入力で停止しない', () {
      // 停止艇の評価でこの組み合わせが実際に渡る。無限ループにならないこと。
      expect(
        sweepNorth(square(10, 0, 3), speed: 0, horizonSeconds: 0).intersects,
        isFalse,
      );
      expect(
        sweepNorth(square(1, 0, 3), speed: 0, horizonSeconds: 0).intersects,
        isTrue,
      );
    });
  });

  group('他艇判定(相対運動)', () {
    test('相対速度の掃引は、相手が止まっていれば静的掃引と一致する', () {
      final other = square(0, 100, 3);
      final relative = service.sweepRelative(
        movingPolygon: moving,
        otherPolygon: other,
        origin: _origin,
        relativeVelocityEastMetersPerSecond: 0,
        relativeVelocityNorthMetersPerSecond: northSpeed,
        horizonSeconds: 25,
      );
      final statik = sweepNorth(other, horizonSeconds: 25);

      expect(relative.intersects, statik.intersects);
      expect(
        relative.firstEntryTimeSeconds,
        closeTo(statik.firstEntryTimeSeconds!, 1e-6),
      );
    });

    test('同じ向きに同じ速さで進む2艇は衝突しない(相対速度0)', () {
      final result = service.sweepRelative(
        movingPolygon: moving,
        otherPolygon: square(0, 30, 3),
        origin: _origin,
        relativeVelocityEastMetersPerSecond: 0,
        relativeVelocityNorthMetersPerSecond: 0,
        horizonSeconds: 10,
      );

      expect(result.intersects, isFalse);
      expect(result.minimumSeparationMeters, closeTo(25.0, 0.01));
    });
  });

  group('退化・不正な入力', () {
    test('頂点が3点に満たない入力は例外を投げる', () {
      expect(
        () => sweepNorth([at(0, 100), at(4, 100)]),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => service.sweepAgainstStatic(
          movingPolygon: [at(0, 0), at(4, 0)],
          staticPolygon: square(0, 100, 3),
          origin: _origin,
          velocityEastMetersPerSecond: 0,
          velocityNorthMetersPerSecond: northSpeed,
          horizonSeconds: 10,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('共線に潰れた区域は例外を投げる(呼び出し側フォールバックの前提)', () {
      expect(
        () => sweepNorth([at(0, 100), at(10, 100), at(20, 100), at(5, 100)]),
        throwsA(isA<FormatException>()),
      );
    });

    test('共線に潰れた自艇領域は例外を投げる', () {
      // 凸包が3点未満になる入力。呼び出し側は捕捉して保守的判定へ落とす。
      expect(
        () => service.sweepAgainstStatic(
          movingPolygon: [at(0, 0), at(2, 0), at(4, 0), at(6, 0)],
          staticPolygon: square(0, 100, 3),
          origin: _origin,
          velocityEastMetersPerSecond: 0,
          velocityNorthMetersPerSecond: northSpeed,
          horizonSeconds: 10,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('地平・拡張量の異常値は例外を投げる', () {
      expect(
        () => sweepNorth(square(0, 100, 3), horizonSeconds: double.nan),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => sweepNorth(square(0, 100, 3), horizonSeconds: -1),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => sweepNorth(square(0, 100, 3), inflateMeters: -1),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('自己交差(蝶ネクタイ)は例外にならず、検知は残る', () {
      // 実測(P02)どおり、耳刈り取りは蝶ネクタイでは例外を投げない。
      // 分割された三角形の和は元の形と一致しないが、外れる向きは
      // **警告を増やす側**で、突っ込んでいく艇を見落とさない。
      // ここが黙って「脅威なし」を返さないことが、呼び出し側の
      // フォールバック(例外時のみ働く)の前提になっている。
      final bowtie = [at(-10, 40), at(10, 40), at(-10, 60), at(10, 60)];
      final result = sweepNorth(bowtie, horizonSeconds: 20);

      expect(result.intersects, isTrue);
      expect(result.firstEntryTimeSeconds, isNotNull);
      expect(result.firstEntryTimeSeconds!, greaterThan(0));
    });
  });

  group('combine', () {
    test('先に侵入するほうの時刻を残す', () {
      final early = sweepNorth(square(0, 30, 3), horizonSeconds: 25);
      final late = sweepNorth(square(0, 100, 3), horizonSeconds: 25);
      final combined = service.combine(early, late);

      expect(combined.intersects, isTrue);
      expect(
        combined.firstEntryTimeSeconds,
        closeTo(early.firstEntryTimeSeconds!, 1e-9),
      );
      expect(
        combined.firstExitTimeSeconds,
        closeTo(late.firstExitTimeSeconds!, 1e-9),
      );
    });

    test('どちらも重ならなければ最接近距離の小さいほうを引き継ぐ', () {
      final near = sweepNorth(square(10, 50, 3), horizonSeconds: 20);
      final far = sweepNorth(square(30, 50, 3), horizonSeconds: 20);
      final combined = service.combine(near, far);

      expect(combined.intersects, isFalse);
      expect(combined.minimumSeparationMeters, closeTo(5.0, 0.01));
    });
  });

  group('既知の縮退: 辺が共線のときの最接近距離', () {
    // `_polygonDistance` が使う `_segmentsIntersect` は、外積の符号だけで
    // 交差を判定する。**共線だが重なっていない**辺の組(平行かつ同一直線上)は
    // 外積が全て0になるため「交差」と判定され、距離0が返る。
    //
    // 帰結は `minimumSeparationMeters` が実際より小さく(0に)出ること。
    // これは `intersects` の判定には一切使われず(SATの軸判定が決める)、
    // 効くのは `nearMissSeparationMeters`(2.0m)によるlv1(表示のみ)と
    // 記録上のすれ違い余裕だけである。すなわち**過剰警告側**であり、
    // 警告漏れにはならない。
    //
    // 実データでは、艇の六角形領域は針路に応じて回転し、区域は任意形状なので
    // 厳密な共線(1e-9 m²)はまず起きない。上の各テストが自艇(半幅2m)と
    // 区域(半幅3m)で寸法を変えているのは、この縮退を踏まないためである。
    //
    // `_segmentsIntersect` を直す場合は、このテストの期待値を実距離
    // (下の例では 46.0m)へ更新すること。
    test('自艇と同寸の区域(辺が共線)では最接近距離が0に潰れる', () {
      final aligned = square(0, 100, 2); // 自艇と同じ半幅 → 左右の辺が共線
      final result = sweepNorth(aligned, horizonSeconds: 10);

      expect(result.intersects, isFalse, reason: '検知そのものは正しい');
      expect(result.minimumSeparationMeters, 0);
    });
  });
}
