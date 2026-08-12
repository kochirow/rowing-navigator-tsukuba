import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:rowing_navigator/services/gps_position_filter.dart';
import 'package:rowing_navigator/services/robust_position_estimator.dart';

Position position({
  required double latitude,
  required double longitude,
  required DateTime timestamp,
  double accuracy = 5,
}) =>
    Position(
      latitude: latitude,
      longitude: longitude,
      timestamp: timestamp,
      accuracy: accuracy,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
      isMocked: true,
    );

void main() {
  GpsPositionFilter newFilter() => GpsPositionFilter(
        maxAccuracyMeters: 25,
        maxSpeedMetersPerSecond: 10,
      );

  test('production相当設定ではmock測位を棄却する', () {
    final now = DateTime(2026, 7, 13, 12);
    final filter = GpsPositionFilter(
      maxAccuracyMeters: 25,
      maxSpeedMetersPerSecond: 10,
      rejectMocked: true,
    );
    final result = filter.evaluate(
      position(latitude: 36.08, longitude: 140.12, timestamp: now),
      receivedAt: now,
    );
    expect(result.accepted, isFalse);
    expect(result.reason, GpsPositionFilterReason.mocked);
  });

  test('精度0の測位を棄却する', () {
    final now = DateTime(2026, 7, 13, 12);
    final result = newFilter().evaluate(
      position(
        latitude: 36.08,
        longitude: 140.12,
        timestamp: now,
        accuracy: 0,
      ),
      receivedAt: now,
    );
    expect(result.accepted, isFalse);
    expect(result.reason, GpsPositionFilterReason.invalidAccuracy);
  });

  test('精度がしきい値を超える測位を棄却する', () {
    final now = DateTime(2026, 7, 13, 12);
    final result = newFilter().evaluate(
      position(
        latitude: 36.08,
        longitude: 140.12,
        timestamp: now,
        accuracy: 26,
      ),
      receivedAt: now,
    );
    expect(result.accepted, isFalse);
    expect(result.reason, GpsPositionFilterReason.lowAccuracy);
  });

  test('精度が悪くても座標が正常なら航行開始の足掛かりにはできる', () {
    final now = DateTime(2026, 7, 25, 12);
    final poorFix = position(
      latitude: 36.08,
      longitude: 140.12,
      timestamp: now,
      accuracy: 120,
    );

    expect(newFilter().hasValidCoordinates(poorFix), isTrue);
    expect(
      newFilter().accepts(poorFix, receivedAt: now),
      isFalse,
    );
    final robustFilter = GpsPositionFilter(
      maxAccuracyMeters: 25,
      maxSpeedMetersPerSecond: 10,
      acceptLowAccuracy: true,
    );
    expect(
      robustFilter.accepts(poorFix, receivedAt: now),
      isTrue,
    );
  });

  test('カルマン有効時は低精度による見かけの位置飛びも推定器へ渡す', () {
    final now = DateTime(2026, 7, 25, 12);
    final filter = GpsPositionFilter(
      maxAccuracyMeters: 25,
      maxSpeedMetersPerSecond: 10,
      acceptLowAccuracy: true,
    );
    expect(
      filter.accepts(
        position(latitude: 36.08, longitude: 140.12, timestamp: now),
        receivedAt: now,
      ),
      isTrue,
    );
    expect(
      filter.accepts(
        position(
          latitude: 36.0803,
          longitude: 140.12,
          timestamp: now.add(const Duration(seconds: 1)),
          accuracy: 80,
        ),
        receivedAt: now.add(const Duration(seconds: 1)),
      ),
      isTrue,
    );
  });

  test('範囲外の座標は航行開始の足掛かりにも使わない', () {
    final now = DateTime(2026, 7, 25, 12);
    expect(
      newFilter().hasValidCoordinates(
        position(latitude: 91, longitude: 140.12, timestamp: now),
      ),
      isFalse,
    );
  });

  test('現実的でない位置飛びを棄却する', () {
    final now = DateTime(2026, 7, 13, 12);
    final filter = newFilter();
    expect(
      filter.accepts(
        position(latitude: 36.08, longitude: 140.12, timestamp: now),
        receivedAt: now,
      ),
      isTrue,
    );
    final next = now.add(const Duration(seconds: 1));
    final result = filter.evaluate(
      position(latitude: 36.09, longitude: 140.12, timestamp: next),
      receivedAt: next,
    );
    expect(result.accepted, isFalse);
    expect(result.reason, GpsPositionFilterReason.implausibleSpeed);
    expect(result.previousAccuracyMeters, 5);
    expect(result.distanceMeters, greaterThan(1000));
    expect(result.elapsedSeconds, 1);
  });

  test('低精度の基準点から離れた良好fixを推定器へ渡す', () {
    final now = DateTime(2026, 8, 6, 12);
    final filter = GpsPositionFilter(
      maxAccuracyMeters: 25,
      maxSpeedMetersPerSecond: 10,
      acceptLowAccuracy: true,
    );
    final roughBootstrap = position(
      latitude: 36.08141,
      longitude: 140.21385,
      timestamp: now,
      accuracy: 1026.5,
    );
    final goodFix = position(
      latitude: 36.08182,
      longitude: 140.21481,
      timestamp: now.add(const Duration(seconds: 2)),
      accuracy: 3.54,
    );

    expect(
      filter
          .evaluate(
            roughBootstrap,
            receivedAt: now,
            receivedElapsed: Duration.zero,
          )
          .accepted,
      isTrue,
    );
    final result = filter.evaluate(
      goodFix,
      receivedAt: now.add(const Duration(seconds: 2)),
      receivedElapsed: const Duration(seconds: 2),
    );

    expect(result.accepted, isTrue);
    expect(result.reason, GpsPositionFilterReason.lowAccuracyAnchorBypassed);
    expect(result.previousAccuracyMeters, 1026.5);
    expect(result.distanceMeters, inInclusiveRange(90, 110));
    expect(result.elapsedSeconds, 2);
  });

  test('良好な基準点からの高精度な異常jumpは従来どおり棄却する', () {
    final now = DateTime(2026, 8, 6, 12);
    final filter = GpsPositionFilter(
      maxAccuracyMeters: 25,
      maxSpeedMetersPerSecond: 10,
      acceptLowAccuracy: true,
    );
    expect(
      filter
          .evaluate(
            position(
              latitude: 36.08182,
              longitude: 140.21481,
              timestamp: now,
              accuracy: 3.54,
            ),
            receivedAt: now,
            receivedElapsed: Duration.zero,
          )
          .accepted,
      isTrue,
    );

    final result = filter.evaluate(
      position(
        latitude: 36.09182,
        longitude: 140.21481,
        timestamp: now.add(const Duration(seconds: 1)),
        accuracy: 4,
      ),
      receivedAt: now.add(const Duration(seconds: 1)),
      receivedElapsed: const Duration(seconds: 1),
    );

    expect(result.accepted, isFalse);
    expect(result.reason, GpsPositionFilterReason.implausibleSpeed);
  });

  test('良好anchorから離れた良好fixも一貫した3点で再捕捉する', () {
    final now = DateTime(2026, 8, 13, 12);
    final filter = GpsPositionFilter(
      maxAccuracyMeters: 25,
      maxSpeedMetersPerSecond: 10,
      acceptLowAccuracy: true,
    );
    expect(
      filter
          .evaluate(
            position(
              latitude: 36.08000,
              longitude: 140.12000,
              timestamp: now,
            ),
            receivedAt: now,
            receivedElapsed: Duration.zero,
          )
          .accepted,
      isTrue,
    );

    GpsPositionFilterResult? result;
    for (var second = 1; second <= 3; second++) {
      final at = now.add(Duration(seconds: second));
      result = filter.evaluate(
        position(
          latitude: 36.09000,
          longitude: 140.12000 + second * 0.00001,
          timestamp: at,
        ),
        receivedAt: at,
        receivedElapsed: Duration(seconds: second),
      );
      expect(result.accepted, second == 3);
    }
    expect(result!.speedAnchorReacquired, isTrue);

    // anchorが付け替わった後は、新しい場所の次fixも通る。
    final next = now.add(const Duration(seconds: 4));
    final continued = filter.evaluate(
      position(
        latitude: 36.09000,
        longitude: 140.12004,
        timestamp: next,
      ),
      receivedAt: next,
      receivedElapsed: const Duration(seconds: 4),
    );
    expect(continued.accepted, isTrue);
    expect(continued.speedAnchorReacquired, isFalse);
  });

  test('良好anchorからの単発jumpと2点だけは再捕捉しない', () {
    final now = DateTime(2026, 8, 13, 12);
    final filter = GpsPositionFilter(
      maxAccuracyMeters: 25,
      maxSpeedMetersPerSecond: 10,
      acceptLowAccuracy: true,
    );
    expect(
      filter
          .evaluate(
            position(latitude: 36.08, longitude: 140.12, timestamp: now),
            receivedAt: now,
            receivedElapsed: Duration.zero,
          )
          .accepted,
      isTrue,
    );

    for (var second = 1; second <= 2; second++) {
      final at = now.add(Duration(seconds: second));
      final result = filter.evaluate(
        position(
          latitude: 36.09,
          longitude: 140.12 + second * 0.00001,
          timestamp: at,
        ),
        receivedAt: at,
        receivedElapsed: Duration(seconds: second),
      );
      expect(result.accepted, isFalse);
      expect(result.reason, GpsPositionFilterReason.implausibleSpeed);
    }
  });

  test('候補間が異常速度なら再起算し、誤再捕捉しない', () {
    final now = DateTime(2026, 8, 13, 12);
    final filter = GpsPositionFilter(
      maxAccuracyMeters: 25,
      maxSpeedMetersPerSecond: 10,
      acceptLowAccuracy: true,
    );
    expect(
      filter
          .evaluate(
            position(latitude: 36.08, longitude: 140.12, timestamp: now),
            receivedAt: now,
            receivedElapsed: Duration.zero,
          )
          .accepted,
      isTrue,
    );

    // 候補1と候補2の間自体が約1km/sであり、候補列はここでresetされる。
    final candidates = [
      (1, 36.09000),
      (2, 36.10000),
      (3, 36.10001),
    ];
    for (final (second, latitude) in candidates) {
      final at = now.add(Duration(seconds: second));
      final result = filter.evaluate(
        position(latitude: latitude, longitude: 140.12, timestamp: at),
        receivedAt: at,
        receivedElapsed: Duration(seconds: second),
      );
      expect(result.accepted, isFalse);
      expect(result.speedAnchorReacquired, isFalse);
    }
  });

  test('実機相当の粗いbootstrap後に良好fixで有限時間内に捕捉する', () {
    final now = DateTime(2026, 8, 6, 12);
    final filter = GpsPositionFilter(
      maxAccuracyMeters: 25,
      maxSpeedMetersPerSecond: 10,
      acceptLowAccuracy: true,
    );
    final estimator = RobustPositionEstimator();
    final bootstrap = position(
      latitude: 36.08141,
      longitude: 140.21385,
      timestamp: now,
      accuracy: 1026.5,
    );
    expect(
      filter
          .evaluate(
            bootstrap,
            receivedAt: now,
            receivedElapsed: Duration.zero,
          )
          .accepted,
      isTrue,
    );
    final bootstrapEstimate = estimator.update(
      latitude: bootstrap.latitude,
      longitude: bootstrap.longitude,
      accuracyMeters: bootstrap.accuracy,
      elapsed: Duration.zero,
      speedMetersPerSecond: bootstrap.speed,
      headingDegrees: bootstrap.heading,
    );
    expect(
      bootstrapEstimate!.disposition,
      PositionEstimateDisposition.initialized,
    );

    // 実際の航行開始と同じく、bootstrapで推定器も初期化する。
    // その後の一貫した良好fixが入口を通り、古い粗い座標に固定されないことを確かめる。
    RobustPositionEstimate? estimate;
    final fixes = [
      (2, 36.08182, 140.21481, 3.54),
      (3, 36.08182, 140.21482, 3.54),
      (4, 36.08182, 140.21483, 4.70),
    ];
    for (final (second, latitude, longitude, accuracy) in fixes) {
      final fix = position(
        latitude: latitude,
        longitude: longitude,
        timestamp: now.add(Duration(seconds: second)),
        accuracy: accuracy,
      );
      final filterResult = filter.evaluate(
        fix,
        receivedAt: now.add(Duration(seconds: second)),
        receivedElapsed: Duration(seconds: second),
      );
      expect(filterResult.accepted, isTrue);
      estimate = estimator.update(
        latitude: fix.latitude,
        longitude: fix.longitude,
        accuracyMeters: fix.accuracy,
        elapsed: Duration(seconds: second),
        speedMetersPerSecond: fix.speed,
        headingDegrees: fix.heading,
      );
      expect(estimate, isNotNull);
      expect(
          estimate!.disposition, isNot(PositionEstimateDisposition.rejected));
    }

    expect(estimate!.longitude, closeTo(140.21483, 0.00002));
  });

  test('古い測位と時刻が逆行した測位を棄却する', () {
    final now = DateTime(2026, 7, 13, 12);
    final filter = newFilter();
    final stale = filter.evaluate(
      position(
        latitude: 36.08,
        longitude: 140.12,
        timestamp: now.subtract(const Duration(seconds: 11)),
      ),
      receivedAt: now,
    );
    expect(stale.accepted, isFalse);
    expect(stale.reason, GpsPositionFilterReason.staleTimestamp);

    expect(
      filter.accepts(
        position(latitude: 36.08, longitude: 140.12, timestamp: now),
        receivedAt: now,
      ),
      isTrue,
    );
    final nonMonotonic = filter.evaluate(
      position(
        latitude: 36.08001,
        longitude: 140.12,
        timestamp: now,
      ),
      receivedAt: now,
    );
    expect(nonMonotonic.accepted, isFalse);
    expect(nonMonotonic.reason, GpsPositionFilterReason.nonMonotonic);
  });

  test('端末時計が戻っても単調な受信時刻で新しい測位を受理する', () {
    final wall = DateTime(2026, 7, 13, 12);
    final filter = newFilter();
    expect(
      filter.accepts(
        position(latitude: 36.08, longitude: 140.12, timestamp: wall),
        receivedAt: wall,
        receivedElapsed: Duration.zero,
      ),
      isTrue,
    );
    expect(
      filter.accepts(
        position(
          latitude: 36.08001,
          longitude: 140.12,
          timestamp: wall.subtract(const Duration(seconds: 60)),
        ),
        receivedAt: wall.subtract(const Duration(seconds: 60)),
        receivedElapsed: const Duration(seconds: 1),
      ),
      isTrue,
    );
  });

  test('航行Stopwatchのreset後も直前fixから単調時刻で継続する', () {
    final now = DateTime(2026, 7, 13, 12);
    final filter = newFilter();
    expect(
      filter.accepts(
        position(latitude: 36.08, longitude: 140.12, timestamp: now),
        receivedAt: now,
        receivedElapsed: const Duration(minutes: 3),
      ),
      isTrue,
    );
    filter.rebaseLastAcceptedElapsed(Duration.zero);
    expect(
      filter.accepts(
        position(
          latitude: 36.08001,
          longitude: 140.12,
          timestamp: now.add(const Duration(seconds: 1)),
        ),
        receivedAt: now.add(const Duration(seconds: 1)),
        receivedElapsed: const Duration(seconds: 1),
      ),
      isTrue,
    );
  });
}
