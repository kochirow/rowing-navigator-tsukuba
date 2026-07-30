import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/message_service.dart';
import 'package:rowing_navigator/services/other_boat_track_store.dart';

void main() {
  final t0 = DateTime.utc(2026, 7, 28, 6, 0, 0);

  test('個別レコード拒否は30秒で診断保持から消える', () {
    final retention = RejectedBoatIdRetention();

    retention.record('boat-a', at: t0);
    retention.prune(now: t0.add(const Duration(seconds: 29)));
    expect(retention.contains('boat-a'), isTrue);

    retention.prune(now: t0.add(const Duration(seconds: 30)));
    expect(retention.contains('boat-a'), isFalse);
  });

  test('同じ艇が後で受理されたら拒否の診断保持を即座に消す', () {
    final retention = RejectedBoatIdRetention();

    retention.record('boat-a', at: t0);
    retention.accept('boat-a');

    expect(retention.length, 0);
  });

  test('個別レコード診断は艇IDを匿名化し、検証理由だけを残す', () {
    final fault = RecordFault.fromTrackUpdate(
      boatId: 'boat-a-private-id',
      status: OtherBoatTrackUpdateStatus.rejectedInvalidMessage,
    );

    final details = fault.toDiagnosticDetails();
    expect(details['boatIdHash'], hasLength(8));
    expect(details.values.join(), isNot(contains('boat-a-private-id')));
    expect(details['status'], 'rejectedInvalidMessage');
  });
}
