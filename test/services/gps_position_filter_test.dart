import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:rowing_navigator/services/gps_position_filter.dart';

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
    expect(
      filter.accepts(
        position(latitude: 36.08, longitude: 140.12, timestamp: now),
        receivedAt: now,
      ),
      isFalse,
    );
  });

  test('精度0の測位を棄却する', () {
    final now = DateTime(2026, 7, 13, 12);
    expect(
      newFilter().accepts(
        position(
          latitude: 36.08,
          longitude: 140.12,
          timestamp: now,
          accuracy: 0,
        ),
        receivedAt: now,
      ),
      isFalse,
    );
  });

  test('精度がしきい値を超える測位を棄却する', () {
    final now = DateTime(2026, 7, 13, 12);
    expect(
      newFilter().accepts(
        position(
          latitude: 36.08,
          longitude: 140.12,
          timestamp: now,
          accuracy: 26,
        ),
        receivedAt: now,
      ),
      isFalse,
    );
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
    expect(
      filter.accepts(
        position(latitude: 36.09, longitude: 140.12, timestamp: next),
        receivedAt: next,
      ),
      isFalse,
    );
  });

  test('古い測位と時刻が逆行した測位を棄却する', () {
    final now = DateTime(2026, 7, 13, 12);
    final filter = newFilter();
    expect(
      filter.accepts(
        position(
          latitude: 36.08,
          longitude: 140.12,
          timestamp: now.subtract(const Duration(seconds: 11)),
        ),
        receivedAt: now,
      ),
      isFalse,
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
          latitude: 36.08001,
          longitude: 140.12,
          timestamp: now,
        ),
        receivedAt: now,
      ),
      isFalse,
    );
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
