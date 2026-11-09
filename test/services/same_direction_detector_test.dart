import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import 'package:rowing_navigator/services/same_direction_detector.dart';
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
  Map<String, SameDirectionRelation> run(
    SameDirectionDetector detector, {
    required int seconds,
    required Boat Function(int second) other,
    double ownSpeed = speed,
  }) {
    var result = <String, SameDirectionRelation>{};
    for (var second = 0; second <= seconds; second++) {
      final own = boat('own', second, reportedSpeed: ownSpeed);
      final latest = other(second - second % 2);
      result = detector.update(
          own: own,
          others: [latest]).map((id, status) => MapEntry(id, status.relation));
    }
    return result;
  }

  const same = SameDirectionRelation.sameDirection;
  const net = SameDirectionRelation.overtakingSafetyNet;

  test('向きの差30°以内なら、最初の受信から同じ向きになる(10秒待たない)', () {
    expect(
      run(SameDirectionDetector(),
          seconds: 0, other: (s) => boat('b', s, lateral: 6)),
      {'b': same},
    );
  });

  test('並走でも縦列でも、距離が変わっていても同じ向き', () {
    expect(
        run(SameDirectionDetector(),
            seconds: 20,
            other: (s) => boat('b', s, along: 8 * (s % 4 - 2), lateral: 6)),
        {'b': same});
    expect(
        run(SameDirectionDetector(),
            seconds: 20, other: (s) => boat('b', s, along: -15, lateral: 1)),
        {'b': same});
    expect(
        run(SameDirectionDetector(),
            seconds: 20,
            other: (s) => boat('b', s, along: 60 - s * 1.0, lateral: 6)),
        {'b': same});
  });

  test('相手の送ってきた速さが実際より遅くても、同じ向きと判定する', () {
    // 2026-11-07 実機: 並走中に相手の速さが1.5〜2.0m/sで届いた。
    expect(
      run(SameDirectionDetector(),
          seconds: 12,
          other: (s) => boat('b', s, lateral: 8, reportedSpeed: 1.8)),
      {'b': same},
    );
  });

  test('向きの差が30°を超えれば同じ向きではない', () {
    expect(
      run(SameDirectionDetector(),
          seconds: 4,
          other: (s) => boat('b', s, lateral: 10, boatHeading: heading + 30)),
      {'b': same},
    );
    expect(
      run(SameDirectionDetector(),
          seconds: 4,
          other: (s) => boat('b', s, lateral: 10, boatHeading: heading + 31)),
      isEmpty,
    );
  });

  test('自艇か相手の向きが信頼できない(0.5m/s未満)ときは同じ向きとしない', () {
    expect(
      run(SameDirectionDetector(),
          seconds: 4, ownSpeed: 0.3, other: (s) => boat('b', s, lateral: 10)),
      isEmpty,
    );
    expect(
      run(SameDirectionDetector(),
          seconds: 4,
          other: (s) => boat('b', s, lateral: 10, reportedSpeed: 0.3)),
      isEmpty,
    );
  });

  test('相手が一覧から消えたら同じ向きではない', () {
    final detector = SameDirectionDetector();
    run(detector, seconds: 4, other: (s) => boat('b', s, lateral: 10));
    expect(detector.update(own: boat('own', 5), others: const []), isEmpty);
  });

  group('追いつく側の安全網', () {
    test('前の艇が進路上(横0.5m)に残り、4秒以内に当たるなら安全網', () {
      // 1m/s差。前後の距離 − 艇の長さ(4+ 13.4m)が4m以内で鳴る。
      final detector = SameDirectionDetector();
      final relations = <int, SameDirectionRelation?>{};
      for (var second = 0; second <= 30; second++) {
        final own = boat('own', second);
        final other = boat('b', second - second % 2,
            along: 40 - (second - second % 2) * 1.0, lateral: 0.5);
        relations[second] =
            detector.update(own: own, others: [other])['b']?.relation;
      }
      // 前後の距離が13.4+4=17.4m以下(23秒目以降)で安全網。
      expect(relations[18], same);
      expect(relations[24], net);
      expect(relations[26], net);
    });

    test('横4mで抜くときは、横に並ぶ手前の数秒だけ安全網になり、並んだら終える', () {
      // 測位の誤差(相対約2.5m)では、真後ろと横4mを見分けられない(2026-11-09)。
      final detector = SameDirectionDetector();
      final relations = <int, SameDirectionRelation?>{};
      for (var second = 0; second <= 36; second++) {
        final reported = second - second % 2;
        relations[second] = detector.update(
          own: boat('own', second),
          others: [boat('b', reported, along: 40 - reported * 1.0, lateral: 4)],
        )['b']?.relation;
      }
      expect(relations[18], same); // 前後22m: まだ先
      expect(relations[24], net); // 前後16m: 艇首が艇尾に届く手前
      expect(relations[30], same); // 前後10m: 横に並んだので終える
      // 1m/s差なら、4秒前 + 測位の誤差の分(2m) + 受信間隔(2秒)で約8秒。
      expect(relations.values.where((r) => r == net).length, lessThan(10));
    });

    test('横に8mより離れて抜くなら安全網にならない', () {
      final detector = SameDirectionDetector();
      for (var second = 0; second <= 36; second++) {
        final reported = second - second % 2;
        final status = detector.update(
          own: boat('own', second),
          others: [
            boat('b', reported, along: 40 - reported * 1.0, lateral: 10)
          ],
        )['b'];
        expect(status?.relation, same, reason: '$second秒');
      }
    });

    test('同じ速さで後ろを追いかけているだけなら安全網にならない', () {
      // 1m後ろ(艇首と艇尾の間が1m)でも、近づいていなければ鳴らさない。
      expect(
        run(SameDirectionDetector(),
            seconds: 30, other: (s) => boat('b', s, along: 14.4, lateral: 0.5)),
        {'b': same},
      );
    });

    test('相手が後ろから追いついてくる側(自艇が前)には安全網を出さない', () {
      expect(
        run(SameDirectionDetector(),
            seconds: 30,
            other: (s) => boat('b', s, along: -40 + s * 1.0, lateral: 0.5)),
        {'b': same},
      );
    });

    test('同じ向きの記録が5秒に満たなければ安全網は判定しない', () {
      final detector = SameDirectionDetector();
      final result = run(detector,
          seconds: 4,
          other: (s) => boat('b', s, along: 16 - s * 1.0, lateral: 0));
      expect(result, {'b': same});
    });
  });
}
