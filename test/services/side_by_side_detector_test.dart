import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import 'package:rowing_navigator/services/side_by_side_detector.dart';
import 'package:rowing_navigator/types/boat_type.dart';
import 'package:rowing_navigator/utils/geo_math.dart';

void main() {
  final t0 = DateTime.utc(2026, 11, 6, 22);
  const start = LatLng(36.075, 140.21);
  const heading = 115.0;
  const speed = 3.5;

  Boat boat(
    String id,
    int second, {
    double lateral = 0,
    double along = 0,
    double boatHeading = heading,
    double reportedSpeed = speed,
    double trueSpeed = speed,
  }) {
    final forward = computeOffset(start, trueSpeed * second + along, heading);
    final position = computeOffset(forward, lateral, heading + 90);
    return Boat(
      boatId: id,
      boatType: BoatType.r_4p,
      lat: position.latitude,
      lng: position.longitude,
      heading: boatHeading,
      speed: reportedSpeed,
      timestamp: t0.add(Duration(seconds: second)),
    );
  }

  /// 自艇は毎秒、相手は2秒おきに届く。
  Set<String> run(
    SideBySideDetector detector, {
    required int seconds,
    required Boat Function(int second) other,
    double ownSpeed = speed,
  }) {
    var result = <String>{};
    for (var second = 0; second <= seconds; second++) {
      final own = boat('own', second, reportedSpeed: ownSpeed);
      final latest = other(second - second % 2);
      result = detector.update(own: own, others: [latest]);
    }
    return result;
  }

  test('同じ向き・横10m・距離が一定なら、10秒たって並走になる', () {
    final detector = SideBySideDetector();
    expect(run(detector, seconds: 8, other: (s) => boat('b', s, lateral: 10)),
        isEmpty);
    expect(
      run(SideBySideDetector(),
          seconds: 12, other: (s) => boat('b', s, lateral: 10)),
      {'b'},
    );
  });

  test('相手の送ってきた速さが実際より遅くても、位置で並走と判定する', () {
    // 2026-11-07 実機: 並走中に相手の速さが1.5〜2.0m/sで届いた。
    expect(
      run(SideBySideDetector(),
          seconds: 12,
          other: (s) => boat('b', s, lateral: 8, reportedSpeed: 1.8)),
      {'b'},
    );
  });

  test('10秒で7m以上近づいていれば並走ではない', () {
    expect(
      run(SideBySideDetector(),
          seconds: 14,
          other: (s) =>
              boat('b', s, along: 40 - s * 1.0, trueSpeed: speed, lateral: 5)),
      isEmpty,
    );
  });

  test('向きの差が45°を超えれば並走ではない', () {
    expect(
      run(SideBySideDetector(),
          seconds: 12,
          other: (s) => boat('b', s, lateral: 10, boatHeading: heading + 50)),
      isEmpty,
    );
  });

  test('横の距離が30mを超えれば並走ではない', () {
    expect(
      run(SideBySideDetector(),
          seconds: 12, other: (s) => boat('b', s, lateral: 35)),
      isEmpty,
    );
  });

  test('自艇の向きが信頼できない(0.5m/s未満)ときは並走としない', () {
    expect(
      run(SideBySideDetector(),
          seconds: 12, ownSpeed: 0.3, other: (s) => boat('b', s, lateral: 10)),
      isEmpty,
    );
  });

  test('並走中に条件が崩れたら、その時点で外れる', () {
    final detector = SideBySideDetector();
    expect(run(detector, seconds: 12, other: (s) => boat('b', s, lateral: 10)),
        {'b'});
    final turned = detector.update(
      own: boat('own', 14),
      others: [boat('b', 14, lateral: 10, boatHeading: heading + 90)],
    );
    expect(turned, isEmpty);
  });

  test('相手が一覧から消えたら並走ではない', () {
    final detector = SideBySideDetector();
    run(detector, seconds: 12, other: (s) => boat('b', s, lateral: 10));
    expect(detector.update(own: boat('own', 13), others: const []), isEmpty);
  });
}
