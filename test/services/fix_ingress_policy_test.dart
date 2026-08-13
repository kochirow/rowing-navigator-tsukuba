import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/fix_batch_collector.dart';
import 'package:rowing_navigator/services/fix_ingress_policy.dart';

void main() {
  test('1Hz fixは到着時刻が近くても全件採用する', () {
    final policy = FixIngressPolicy();
    final origin = DateTime.utc(2026, 8, 6, 12);
    for (var i = 0; i < 5; i++) {
      expect(
        policy
            .decide(
              fixTimestamp: origin.add(Duration(seconds: i)),
              arrivalMonotonic: Duration(milliseconds: 100 * i),
            )
            .accepted,
        isTrue,
      );
    }
  });

  test('700ms未満の同一・重複fixは棄却する', () {
    final policy = FixIngressPolicy();
    final origin = DateTime.utc(2026, 8, 6, 12);
    policy.decide(fixTimestamp: origin, arrivalMonotonic: Duration.zero);
    final duplicate = policy.decide(
      fixTimestamp: origin.add(const Duration(milliseconds: 300)),
      arrivalMonotonic: const Duration(milliseconds: 10),
    );
    expect(duplicate.accepted, isFalse);
    expect(duplicate.rejectionReason!.name, 'duplicate');
  });

  test('時刻逆行は棄却するが10秒継続で基準を回復する', () {
    final policy = FixIngressPolicy();
    final origin = DateTime.utc(2026, 8, 6, 12);
    policy.decide(
      fixTimestamp: origin.add(const Duration(seconds: 20)),
      arrivalMonotonic: Duration.zero,
    );
    expect(
      policy
          .decide(
            fixTimestamp: origin,
            arrivalMonotonic: const Duration(seconds: 1),
          )
          .accepted,
      isFalse,
    );
    final recovered = policy.decide(
      fixTimestamp: origin.add(const Duration(seconds: 1)),
      arrivalMonotonic: const Duration(seconds: 11),
    );
    expect(recovered.accepted, isTrue);
    expect(recovered.kind.name, 'reset');
  });

  test('同一ティックのバッチは時刻順にして最新だけを採る', () {
    final collector = FixBatchCollector<DateTime>((value) => value);
    final origin = DateTime.utc(2026, 8, 6, 12);
    collector
      ..add(origin.add(const Duration(seconds: 2)))
      ..add(origin)
      ..add(origin.add(const Duration(seconds: 1)));
    final batch = collector.takeBatch()!;
    expect(batch.latest, origin.add(const Duration(seconds: 2)));
    expect(batch.superseded, [origin, origin.add(const Duration(seconds: 1))]);
  });
}
