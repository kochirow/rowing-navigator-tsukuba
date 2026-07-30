import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/alert_candidate.dart';

void main() {
  final now = DateTime.utc(2026, 7, 15, 12);

  test('stable ID is independent of observation and presentation fields', () {
    final first = AlertCandidate.stable(
      detectorId: 'other_boat',
      category: 'collision',
      targetId: 'boat/2',
      targetSessionId: 'session-a',
      behavior: AlertBehavior.continuousAction,
      evaluatedAt: now,
      observationId: 'fix-1',
      audioAsset: 'audio/first.mp3',
    );
    final second = AlertCandidate.stable(
      detectorId: 'other_boat',
      category: 'collision',
      targetId: 'boat/2',
      targetSessionId: 'session-a',
      behavior: AlertBehavior.continuousAction,
      evaluatedAt: now.add(const Duration(seconds: 1)),
      observationId: 'fix-2',
      audioAsset: 'audio/renamed.mp3',
    );

    expect(first.alertId, second.alertId);
    expect(first.alertId, contains('boat%2F2'));
  });

  test('a new target session gets a new stable ID', () {
    String id(String session) => AlertCandidate.buildStableAlertId(
          detectorId: 'other_boat',
          category: 'collision',
          targetId: 'boat-2',
          targetSessionId: session,
        );

    expect(id('session-a'), isNot(id('session-b')));
  });

  test('candidate defensively copies reason codes', () {
    final reasons = ['CPA_INSIDE_DOMAIN'];
    final candidate = AlertCandidate.stable(
      detectorId: 'other_boat',
      category: 'collision',
      behavior: AlertBehavior.continuousAction,
      evaluatedAt: now,
      observationId: 'fix-1',
      reasonCodes: reasons,
    );
    reasons.add('MUTATED');

    expect(candidate.reasonCodes, ['CPA_INSIDE_DOMAIN']);
    expect(() => candidate.reasonCodes.add('x'), throwsUnsupportedError);
  });

  test('copyWithで提示段階と音声イベントを安全に切り替えられる', () {
    final candidate = AlertCandidate.stable(
      detectorId: 'static_collision',
      category: 'shore',
      targetId: 'shore-a',
      behavior: AlertBehavior.continuousAction,
      evaluatedAt: now,
      observationId: 'fix-1',
      audioAsset: 'audio/shore_warning.mp3',
      audioEventId: 'risk-1',
    );

    final visual = candidate.copyWith(
      behavior: AlertBehavior.visualOnly,
      clearAudioAsset: true,
      clearAudioEventId: true,
    );

    expect(visual.alertId, candidate.alertId);
    expect(visual.behavior, AlertBehavior.visualOnly);
    expect(visual.audioAsset, isNull);
    expect(visual.audioEventId, isNull);
  });

  test('将来の物理交差だけを推測警告と判別する', () {
    AlertCandidate value({
      required AlertBehavior behavior,
      required bool overlap,
      Duration? deadline,
    }) =>
        AlertCandidate.stable(
          detectorId: 'detector',
          category: 'shore',
          behavior: behavior,
          evaluatedAt: now,
          observationId: 'fix',
          currentOverlap: overlap,
          actionDeadline: deadline,
        );

    expect(
      value(
        behavior: AlertBehavior.continuousAction,
        overlap: false,
        deadline: const Duration(seconds: 7),
      ).isPredicted,
      isTrue,
    );
    expect(
      value(
        behavior: AlertBehavior.singleAction,
        overlap: false,
        deadline: const Duration(seconds: 7),
      ).isPredicted,
      isTrue,
    );
    expect(
      value(
        behavior: AlertBehavior.visualOnly,
        overlap: false,
        deadline: const Duration(seconds: 7),
      ).isPredicted,
      isTrue,
    );
    expect(
      value(
        behavior: AlertBehavior.continuousAction,
        overlap: true,
        deadline: Duration.zero,
      ).isPredicted,
      isFalse,
    );
    expect(
      value(
        behavior: AlertBehavior.persistentSystemFault,
        overlap: false,
        deadline: Duration.zero,
      ).isPredicted,
      isFalse,
    );
  });
}
