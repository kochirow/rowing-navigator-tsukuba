import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/fix_envelope.dart';

void main() {
  test('FixEnvelope serializes source, monotonic arrival and rejection reason',
      () {
    final envelope = FixEnvelope(
      sequence: 4,
      source: FixSource.polling,
      arrivedAtMonotonic: const Duration(seconds: 8),
      fixTimestamp: DateTime.utc(2026, 8, 6),
      ageAtArrivalMs: 42,
      deltaFromPreviousFixMs: 1000,
      deltaFromPreviousArrivalMs: 900,
      accuracyMeters: 5,
      accepted: false,
      rejectionReason: FixRejectionReason.throttleWindow,
    );
    expect(envelope.toDiagnosticDetails(), containsPair('source', 'polling'));
    expect(envelope.toDiagnosticDetails(),
        containsPair('rejectionReason', 'throttleWindow'));
  });

  test('速度飛びをstaleと混同せず記録する', () {
    final envelope = FixEnvelope(
      sequence: 5,
      source: FixSource.stream,
      arrivedAtMonotonic: const Duration(seconds: 2),
      fixTimestamp: DateTime.utc(2026, 8, 6),
      ageAtArrivalMs: 30,
      accuracyMeters: 4,
      accepted: false,
      rejectionReason: FixRejectionReason.implausibleSpeed,
    );

    expect(
      envelope.toDiagnosticDetails(),
      containsPair('rejectionReason', 'implausibleSpeed'),
    );
  });
}
