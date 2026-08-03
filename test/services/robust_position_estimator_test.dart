import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/robust_position_estimator.dart';

const originLatitude = 36.08;
const originLongitude = 140.12;
const metersPerLatitudeDegree = 111195.08;

double latitudeAtNorthMeters(double meters) =>
    originLatitude + meters / metersPerLatitudeDegree;

double longitudeAtEastMeters(double meters) =>
    originLongitude +
    meters /
        (metersPerLatitudeDegree * math.cos(originLatitude * math.pi / 180));

void main() {
  group('RobustPositionEstimator', () {
    test('欠測中は5秒まで進行方向へ予測し、不確実性を増やす', () {
      final estimator = RobustPositionEstimator();
      final measured = estimator.update(
        latitude: originLatitude,
        longitude: originLongitude,
        accuracyMeters: 5,
        elapsed: Duration.zero,
        speedMetersPerSecond: 3,
        headingDegrees: 90,
        speedAccuracyMetersPerSecond: 0.5,
        headingAccuracyDegrees: 5,
      )!;

      final predicted = estimator.predict(
        elapsed: const Duration(seconds: 3),
        maxPredictionGap: const Duration(seconds: 5),
      );

      expect(predicted, isNotNull);
      expect(predicted!.disposition, PositionEstimateDisposition.predicted);
      final predictedEast = (predicted.longitude - originLongitude) *
          metersPerLatitudeDegree *
          math.cos(originLatitude * math.pi / 180);
      expect(predictedEast, closeTo(9, 0.2));
      expect(
        predicted.covarianceUncertaintyMeters,
        greaterThan(measured.covarianceUncertaintyMeters),
      );
      expect(
          predicted.uncertaintyMeters, greaterThan(measured.uncertaintyMeters));
    });

    test('推測は最後の統合測位から5秒を超えたら停止する', () {
      final estimator = RobustPositionEstimator();
      estimator.update(
        latitude: originLatitude,
        longitude: originLongitude,
        accuracyMeters: 5,
        elapsed: Duration.zero,
        speedMetersPerSecond: 3,
        headingDegrees: 90,
      );
      expect(
        estimator.predict(
          elapsed: const Duration(seconds: 5),
          maxPredictionGap: const Duration(seconds: 5),
        ),
        isNotNull,
      );
      expect(
        estimator.predict(
          elapsed: const Duration(seconds: 6),
          maxPredictionGap: const Duration(seconds: 5),
        ),
        isNull,
      );
    });

    test('予測後の実測は観測全体の欠測時間で再捕捉する', () {
      final estimator = RobustPositionEstimator();
      estimator.update(
        latitude: originLatitude,
        longitude: originLongitude,
        accuracyMeters: 5,
        elapsed: Duration.zero,
        speedMetersPerSecond: 3,
        headingDegrees: 90,
      );
      estimator.predict(elapsed: const Duration(seconds: 5));

      final recovered = estimator.update(
        latitude: originLatitude,
        longitude: longitudeAtEastMeters(24),
        accuracyMeters: 5,
        elapsed: const Duration(seconds: 8),
        speedMetersPerSecond: 3,
        headingDegrees: 90,
      );

      expect(recovered, isNotNull);
      expect(recovered!.disposition, PositionEstimateDisposition.reacquired);
    });

    test('最初の測位で初期化し、端末精度より楽観的な不確実性にしない', () {
      final estimator = RobustPositionEstimator();

      final estimate = estimator.update(
        latitude: originLatitude,
        longitude: originLongitude,
        accuracyMeters: 5,
        elapsed: Duration.zero,
        speedMetersPerSecond: 3,
        headingDegrees: 90,
        speedAccuracyMetersPerSecond: 0.5,
        headingAccuracyDegrees: 5,
      );

      expect(estimate, isNotNull);
      expect(estimate!.disposition, PositionEstimateDisposition.initialized);
      expect(estimate.latitude, closeTo(originLatitude, 1e-12));
      expect(estimate.longitude, closeTo(originLongitude, 1e-12));
      expect(estimate.speedMetersPerSecond, closeTo(3, 1e-9));
      expect(estimate.headingDegrees, closeTo(90, 1e-9));
      expect(estimate.reportedAccuracyMeters, 5);
      expect(estimate.covarianceUncertaintyMeters, greaterThan(5));
      expect(estimate.uncertaintyMeters,
          greaterThanOrEqualTo(estimate.reportedAccuracyMeters));
    });

    test('局所座標変換で東西・南北の小移動を安定して追従する', () {
      final estimator = RobustPositionEstimator();
      estimator.update(
        latitude: originLatitude,
        longitude: originLongitude,
        accuracyMeters: 4,
        elapsed: Duration.zero,
        speedMetersPerSecond: 2,
        headingDegrees: 45,
      );

      RobustPositionEstimate? estimate;
      for (var second = 1; second <= 5; second++) {
        final distancePerAxis = second * math.sqrt(2);
        estimate = estimator.update(
          latitude: latitudeAtNorthMeters(distancePerAxis),
          longitude: longitudeAtEastMeters(distancePerAxis),
          accuracyMeters: 4,
          elapsed: Duration(seconds: second),
          speedMetersPerSecond: 2,
          headingDegrees: 45,
        );
      }

      expect(estimate, isNotNull);
      expect(estimate!.disposition, PositionEstimateDisposition.accepted);
      expect(
        (estimate.latitude - originLatitude) * metersPerLatitudeDegree,
        closeTo(5 * math.sqrt(2), 1),
      );
      expect(
        (estimate.longitude - originLongitude) *
            metersPerLatitudeDegree *
            math.cos(originLatitude * math.pi / 180),
        closeTo(5 * math.sqrt(2), 1),
      );
      expect(estimate.speedMetersPerSecond, closeTo(2, 0.5));
      expect(estimate.headingDegrees, closeTo(45, 5));
    });

    test('停止中の交互なGPS揺れの総移動量を減らす', () {
      final estimator = RobustPositionEstimator();
      var previousRawEast = 0.0;
      var previousEstimatedEast = 0.0;
      var rawTravel = 0.0;
      var estimatedTravel = 0.0;

      for (var second = 0; second < 12; second++) {
        final rawEast = second.isEven ? -4.0 : 4.0;
        final estimate = estimator.update(
          latitude: originLatitude,
          longitude: longitudeAtEastMeters(rawEast),
          accuracyMeters: 6,
          elapsed: Duration(seconds: second),
          speedMetersPerSecond: 0,
          headingDegrees: 0,
        )!;
        final estimatedEast = (estimate.longitude - originLongitude) *
            metersPerLatitudeDegree *
            math.cos(originLatitude * math.pi / 180);
        if (second > 0) {
          rawTravel += (rawEast - previousRawEast).abs();
          estimatedTravel += (estimatedEast - previousEstimatedEast).abs();
        }
        previousRawEast = rawEast;
        previousEstimatedEast = estimatedEast;
      }

      expect(estimatedTravel, lessThan(rawTravel * 0.6));
    });

    test('低精度の測位は同じ位置の高精度測位より弱く反映する', () {
      RobustPositionEstimate nextEstimate(double accuracyMeters) {
        final estimator = RobustPositionEstimator();
        estimator.update(
          latitude: originLatitude,
          longitude: originLongitude,
          accuracyMeters: 5,
          elapsed: Duration.zero,
        );
        return estimator.update(
          latitude: originLatitude,
          longitude: longitudeAtEastMeters(10),
          accuracyMeters: accuracyMeters,
          elapsed: const Duration(seconds: 1),
        )!;
      }

      double eastOf(RobustPositionEstimate estimate) =>
          (estimate.longitude - originLongitude) *
          metersPerLatitudeDegree *
          math.cos(originLatitude * math.pi / 180);

      expect(eastOf(nextEstimate(4)), greaterThan(eastOf(nextEstimate(20))));
    });

    test('accuracy 80mでも推定を止めず不確実性を保って更新する', () {
      final estimator = RobustPositionEstimator();
      estimator.update(
        latitude: originLatitude,
        longitude: originLongitude,
        accuracyMeters: 5,
        elapsed: Duration.zero,
        speedMetersPerSecond: 3,
        headingDegrees: 90,
      );

      final estimate = estimator.update(
        latitude: originLatitude,
        longitude: longitudeAtEastMeters(12),
        accuracyMeters: 80,
        elapsed: const Duration(seconds: 1),
        speedMetersPerSecond: 3,
        headingDegrees: 90,
      );

      expect(estimate, isNotNull);
      expect(estimate!.latitude.isFinite, isTrue);
      expect(estimate.longitude.isFinite, isTrue);
      // フィルタが収束したぶんは安全マージンへ反映する。ただしマルチパス等の
      // 系統誤差は平均化で消えないため、報告accuracyの半分(=40m)と
      // 絶対下限3mは必ず残し、報告値より楽観的になりすぎない。
      expect(estimate.uncertaintyMeters, greaterThanOrEqualTo(40));
      expect(estimate.uncertaintyMeters, lessThanOrEqualTo(80));
      expect(estimate.reportedAccuracyMeters, 80);
    });

    test('収束後は不確実性が報告accuracyを下回り、安全マージンへ反映される', () {
      final estimator = RobustPositionEstimator();
      RobustPositionEstimate? estimate;
      // 一定の真値へ収束させる。報告accuracyは終始12mのままにする。
      for (var second = 0; second <= 30; second++) {
        estimate = estimator.update(
          latitude: originLatitude,
          longitude: longitudeAtEastMeters(second * 3.0),
          accuracyMeters: 12,
          elapsed: Duration(seconds: second),
          speedMetersPerSecond: 3,
          headingDegrees: 90,
          speedAccuracyMetersPerSecond: 0.4,
          headingAccuracyDegrees: 4,
        );
      }

      expect(estimate, isNotNull);
      expect(estimate!.reportedAccuracyMeters, 12);
      expect(estimate.uncertaintyMeters, lessThan(12));
      // 下限比率(12 × 0.5 = 6m)と絶対下限(3m)は必ず残す。
      expect(estimate.uncertaintyMeters, greaterThanOrEqualTo(6));
    });

    test('横方向のGPS揺れは進行方向の揺れより強く抑える', () {
      // 艇は横滑りしないため、sway方向のプロセスノイズはsurgeより小さい。
      // 同じ揺れの幾何を90度回して与え、揺れが「進行方向に対して横か縦か」
      // だけが違う2条件を比べる。横のほうが強く平滑化されるはず。
      // 速度観測は与えない(与えると速度が固定され、プロセスノイズの差が出ない)。
      double residualFor({required bool lateral}) {
        final estimator = RobustPositionEstimator();
        var residual = 0.0;
        for (var second = 0; second <= 30; second++) {
          final along = second * 3.0;
          final wobble = second.isEven ? -3.0 : 3.0;
          final estimate = estimator.update(
            // lateral: 北へ進みながら東西へ揺れる(横方向の揺れ)
            // それ以外: 東へ進みながら東西へ揺れる(進行方向の揺れ)
            latitude: latitudeAtNorthMeters(lateral ? along : 0),
            longitude: longitudeAtEastMeters(lateral ? wobble : along + wobble),
            accuracyMeters: 5,
            elapsed: Duration(seconds: second),
          )!;
          if (second < 10) continue;
          final estimatedEast = (estimate.longitude - originLongitude) *
              metersPerLatitudeDegree *
              math.cos(originLatitude * math.pi / 180);
          // どちらも東西軸の残差を見る。真値は lateral なら0、そうでなければ along。
          residual += (estimatedEast - (lateral ? 0.0 : along)).abs();
        }
        return residual;
      }

      final lateralResidual = residualFor(lateral: true);
      final longitudinalResidual = residualFor(lateral: false);
      expect(lateralResidual, lessThan(longitudinalResidual * 0.85));
    });

    test('高いSPMほどsurge方向のプロセスノイズを増やし、加減速へ速く追従する', () {
      double estimatedSpeedAfterSurge(double? spm) {
        final estimator = RobustPositionEstimator();
        var east = 0.0;
        // 2m/sで巡航してから4m/sへ加速する。速度観測は与えず、
        // 位置の変化だけからどれだけ速く追従できるかを見る。
        for (var second = 0; second <= 10; second++) {
          if (second > 0) east += 2.0;
          estimator.update(
            latitude: originLatitude,
            longitude: longitudeAtEastMeters(east),
            accuracyMeters: 4,
            elapsed: Duration(seconds: second),
            strokeRateSpm: spm,
          );
        }
        RobustPositionEstimate? estimate;
        for (var second = 11; second <= 14; second++) {
          east += 4.0;
          estimate = estimator.update(
            latitude: originLatitude,
            longitude: longitudeAtEastMeters(east),
            accuracyMeters: 4,
            elapsed: Duration(seconds: second),
            strokeRateSpm: spm,
          );
        }
        return estimate!.speedMetersPerSecond;
      }

      final highRate = estimatedSpeedAfterSurge(36);
      final lowRate = estimatedSpeedAfterSurge(18);
      expect(highRate, greaterThan(lowRate));
      // どちらも目標の4m/sを超えて発散しない。
      expect(highRate, lessThan(5.5));
    });

    test('可変間隔とローイング特有の周期的な速度変動でも発散しない', () {
      final estimator = RobustPositionEstimator();
      var elapsed = Duration.zero;
      var trueEast = 0.0;
      RobustPositionEstimate? estimate;

      for (var index = 0; index < 120; index++) {
        final intervalSeconds = index.isEven ? 0.5 : 1.5;
        final speed = index % 4 < 2 ? 2.0 : 4.0;
        if (index > 0) {
          elapsed += Duration(milliseconds: (intervalSeconds * 1000).round());
          trueEast += speed * intervalSeconds;
        }
        final measurementNoise = index.isEven ? -1.5 : 1.5;
        estimate = estimator.update(
          latitude: originLatitude,
          longitude: longitudeAtEastMeters(trueEast + measurementNoise),
          accuracyMeters: 5,
          elapsed: elapsed,
          speedMetersPerSecond: speed,
          headingDegrees: 90,
          speedAccuracyMetersPerSecond: 0.8,
          headingAccuracyDegrees: 8,
        );
        expect(estimate, isNotNull);
        expect(estimate!.latitude.isFinite, isTrue);
        expect(estimate.longitude.isFinite, isTrue);
        expect(estimate.speedMetersPerSecond.isFinite, isTrue);
        expect(estimate.uncertaintyMeters.isFinite, isTrue);
      }

      final estimatedEast = (estimate!.longitude - originLongitude) *
          metersPerLatitudeDegree *
          math.cos(originLatitude * math.pi / 180);
      expect(estimatedEast, closeTo(trueEast, 4));
      expect(estimate.headingDegrees, closeTo(90, 8));
    });

    test('直進から旋回した後も旧進路へ固定されない', () {
      final estimator = RobustPositionEstimator();
      var north = 0.0;
      var east = 0.0;
      var elapsed = Duration.zero;
      estimator.update(
        latitude: originLatitude,
        longitude: originLongitude,
        accuracyMeters: 4,
        elapsed: elapsed,
        speedMetersPerSecond: 3,
        headingDegrees: 0,
      );
      for (var second = 1; second <= 5; second++) {
        elapsed += const Duration(seconds: 1);
        north += 3;
        estimator.update(
          latitude: latitudeAtNorthMeters(north),
          longitude: longitudeAtEastMeters(east),
          accuracyMeters: 4,
          elapsed: elapsed,
          speedMetersPerSecond: 3,
          headingDegrees: 0,
          speedAccuracyMetersPerSecond: 0.5,
          headingAccuracyDegrees: 5,
        );
      }

      RobustPositionEstimate? estimate;
      for (var second = 1; second <= 5; second++) {
        elapsed += const Duration(seconds: 1);
        east += 3;
        estimate = estimator.update(
          latitude: latitudeAtNorthMeters(north),
          longitude: longitudeAtEastMeters(east),
          accuracyMeters: 4,
          elapsed: elapsed,
          speedMetersPerSecond: 3,
          headingDegrees: 90,
          speedAccuracyMetersPerSecond: 0.5,
          headingAccuracyDegrees: 5,
        );
      }

      expect(estimate, isNotNull);
      expect(estimate!.headingDegrees, closeTo(90, 15));
      final estimatedEast = (estimate.longitude - originLongitude) *
          metersPerLatitudeDegree *
          math.cos(originLatitude * math.pi / 180);
      expect(estimatedEast, greaterThan(10));
    });

    test('中程度のinnovationは棄却せず重みを下げる', () {
      final estimator = RobustPositionEstimator();
      estimator.update(
        latitude: originLatitude,
        longitude: originLongitude,
        accuracyMeters: 4,
        elapsed: Duration.zero,
      );
      estimator.update(
        latitude: originLatitude,
        longitude: originLongitude,
        accuracyMeters: 4,
        elapsed: const Duration(seconds: 1),
      );

      final estimate = estimator.update(
        latitude: originLatitude,
        longitude: longitudeAtEastMeters(18),
        accuracyMeters: 4,
        elapsed: const Duration(seconds: 2),
      );

      expect(estimate, isNotNull);
      expect(estimate!.disposition, PositionEstimateDisposition.downWeighted);
      expect(estimate.innovationMeters, closeTo(18, 0.2));
      final estimatedEast = (estimate.longitude - originLongitude) *
          metersPerLatitudeDegree *
          math.cos(originLatitude * math.pi / 180);
      expect(estimatedEast, greaterThan(0));
      expect(estimatedEast, lessThan(18));
    });

    test('単発の大きな位置飛びは棄却して推定位置を跳ばさない', () {
      final estimator = RobustPositionEstimator();
      estimator.update(
        latitude: originLatitude,
        longitude: originLongitude,
        accuracyMeters: 4,
        elapsed: Duration.zero,
      );
      estimator.update(
        latitude: originLatitude,
        longitude: originLongitude,
        accuracyMeters: 4,
        elapsed: const Duration(seconds: 1),
      );

      final estimate = estimator.update(
        latitude: originLatitude,
        longitude: longitudeAtEastMeters(50),
        accuracyMeters: 4,
        elapsed: const Duration(seconds: 2),
      );

      expect(estimate, isNotNull);
      expect(estimate!.disposition, PositionEstimateDisposition.rejected);
      final estimatedEast = (estimate.longitude - originLongitude) *
          metersPerLatitudeDegree *
          math.cos(originLatitude * math.pi / 180);
      expect(estimatedEast.abs(), lessThan(1));
      expect(estimate.innovationMeters, closeTo(50, 0.3));
    });

    test('新しい妥当な軌跡が3測位続いたらフリーズせず再捕捉する', () {
      final estimator = RobustPositionEstimator();
      estimator.update(
        latitude: originLatitude,
        longitude: originLongitude,
        accuracyMeters: 3,
        elapsed: Duration.zero,
      );

      final dispositions = <PositionEstimateDisposition>[];
      RobustPositionEstimate? estimate;
      for (var second = 1; second <= 3; second++) {
        estimate = estimator.update(
          latitude: originLatitude,
          longitude: longitudeAtEastMeters(40 + second * 3),
          accuracyMeters: 3,
          elapsed: Duration(seconds: second),
        );
        dispositions.add(estimate!.disposition);
      }

      expect(
        dispositions,
        [
          PositionEstimateDisposition.rejected,
          PositionEstimateDisposition.rejected,
          PositionEstimateDisposition.reacquired,
        ],
      );
      final estimatedEast = (estimate!.longitude - originLongitude) *
          metersPerLatitudeDegree *
          math.cos(originLatitude * math.pi / 180);
      expect(estimatedEast, closeTo(49, 0.4));
      expect(estimate.speedMetersPerSecond, closeTo(3, 0.5));
    });

    test('長時間の欠測後は最新測位を再捕捉し、惰行速度を減衰させて引き継ぐ', () {
      final estimator = RobustPositionEstimator();
      estimator.update(
        latitude: originLatitude,
        longitude: originLongitude,
        accuracyMeters: 4,
        elapsed: Duration.zero,
        speedMetersPerSecond: 3,
        headingDegrees: 90,
      );

      // 橋の下のマルチパスなどで8秒欠測した想定。速度観測は得られない。
      final estimate = estimator.update(
        latitude: originLatitude,
        longitude: longitudeAtEastMeters(8),
        accuracyMeters: 5,
        elapsed: const Duration(seconds: 8),
      );

      expect(estimate, isNotNull);
      expect(estimate!.disposition, PositionEstimateDisposition.reacquired);
      final estimatedEast = (estimate.longitude - originLongitude) *
          metersPerLatitudeDegree *
          math.cos(originLatitude * math.pi / 180);
      // 位置は必ず最新測位へ載せ替える(古い速度で外挿しない)。
      expect(estimatedEast, closeTo(8, 0.2));
      // 艇は8秒では止まらない。速度を0にすると停止距離が0になり、
      // 復帰直後だけ警告レベルが不当に下がる。
      final expectedSpeed = 3 * math.exp(-8 / 8);
      expect(estimate.speedMetersPerSecond, closeTo(expectedSpeed, 0.05));
      expect(estimate.speedMetersPerSecond, lessThan(3));
      expect(estimate.speedMetersPerSecond, greaterThan(0));
    });

    test('予測ギャップ以内なら再捕捉せず通常更新を続ける', () {
      final estimator = RobustPositionEstimator();
      estimator.update(
        latitude: originLatitude,
        longitude: originLongitude,
        accuracyMeters: 4,
        elapsed: Duration.zero,
        speedMetersPerSecond: 3,
        headingDegrees: 90,
      );

      final estimate = estimator.update(
        latitude: originLatitude,
        longitude: longitudeAtEastMeters(12),
        accuracyMeters: 5,
        elapsed: const Duration(seconds: 4),
        speedMetersPerSecond: 3,
        headingDegrees: 90,
      );

      expect(estimate, isNotNull);
      expect(
        estimate!.disposition,
        isNot(PositionEstimateDisposition.reacquired),
      );
    });

    test('欠測後に速度観測があれば、惰行の推測より観測を優先する', () {
      final estimator = RobustPositionEstimator();
      estimator.update(
        latitude: originLatitude,
        longitude: originLongitude,
        accuracyMeters: 4,
        elapsed: Duration.zero,
        speedMetersPerSecond: 4,
        headingDegrees: 90,
      );

      final estimate = estimator.update(
        latitude: originLatitude,
        longitude: longitudeAtEastMeters(8),
        accuracyMeters: 5,
        elapsed: const Duration(seconds: 10),
        speedMetersPerSecond: 0,
        headingDegrees: 0,
      );

      expect(estimate, isNotNull);
      expect(estimate!.disposition, PositionEstimateDisposition.reacquired);
      expect(estimate.speedMetersPerSecond, closeTo(0, 1e-9));
    });

    test('時刻の停止・逆行と無効値は状態を変更せずnullを返す', () {
      final estimator = RobustPositionEstimator();
      estimator.update(
        latitude: originLatitude,
        longitude: originLongitude,
        accuracyMeters: 4,
        elapsed: const Duration(seconds: 1),
      );

      expect(
        estimator.update(
          latitude: originLatitude,
          longitude: longitudeAtEastMeters(100),
          accuracyMeters: 4,
          elapsed: const Duration(seconds: 1),
        ),
        isNull,
      );
      expect(
        estimator.update(
          latitude: double.nan,
          longitude: originLongitude,
          accuracyMeters: 4,
          elapsed: const Duration(seconds: 2),
        ),
        isNull,
      );
      final estimate = estimator.update(
        latitude: originLatitude,
        longitude: originLongitude,
        accuracyMeters: 4,
        elapsed: const Duration(seconds: 2),
      );
      expect(estimate, isNotNull);
      expect(estimate!.innovationMeters, lessThan(0.1));
    });

    test('reset後は以前の原点・速度・共分散を引き継がない', () {
      final estimator = RobustPositionEstimator();
      estimator.update(
        latitude: originLatitude,
        longitude: originLongitude,
        accuracyMeters: 4,
        elapsed: Duration.zero,
        speedMetersPerSecond: 3,
        headingDegrees: 90,
      );
      expect(estimator.isInitialized, isTrue);

      estimator.reset();

      expect(estimator.isInitialized, isFalse);
      final estimate = estimator.update(
        latitude: 35,
        longitude: 139,
        accuracyMeters: 6,
        elapsed: Duration.zero,
      );
      expect(estimate!.disposition, PositionEstimateDisposition.initialized);
      expect(estimate.latitude, 35);
      expect(estimate.longitude, 139);
      expect(estimate.speedMetersPerSecond, 0);
    });
  });
}
