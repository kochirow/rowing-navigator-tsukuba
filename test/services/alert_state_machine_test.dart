import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/alert_candidate.dart';
import 'package:rowing_navigator/services/alert_state_machine.dart';

void main() {
  final origin = DateTime.utc(2026, 7, 15, 12);

  AlertCandidate candidate(
    String alertId,
    int seconds,
    String observationId, {
    Duration? deadline = const Duration(seconds: 10),
    bool overlap = false,
    AlertBehavior behavior = AlertBehavior.continuousAction,
    AlertDataQuality quality = AlertDataQuality.good,
    String category = 'hazard',
    int internalPriority = 0,
  }) {
    return AlertCandidate(
      alertId: alertId,
      detectorId: 'detector',
      category: category,
      behavior: behavior,
      evaluatedAt: origin.add(Duration(seconds: seconds)),
      observationId: observationId,
      actionDeadline: deadline,
      currentOverlap: overlap,
      dataQuality: quality,
      internalPriority: internalPriority,
    );
  }

  AlertClearEvidence clear(
    String alertId,
    int seconds,
    String observationId, {
    bool conditionsMet = true,
    AlertDataQuality quality = AlertDataQuality.good,
  }) {
    return AlertClearEvidence(
      alertId: alertId,
      observationId: observationId,
      evaluatedAt: origin.add(Duration(seconds: seconds)),
      dataQuality: quality,
      clearConditionsMet: conditionsMet,
    );
  }

  AlertStateMachineOutput danger(
    AlertStateMachine machine,
    AlertCandidate value,
  ) {
    return machine.process(AlertEvaluationBatch(
      evaluatedAt: value.evaluatedAt,
      candidates: [value],
    ));
  }

  AlertStateMachineOutput safety(
    AlertStateMachine machine,
    AlertClearEvidence value,
  ) {
    return machine.process(AlertEvaluationBatch(
      evaluatedAt: value.evaluatedAt,
      clearEvidence: [value],
    ));
  }

  test('normal start requires two increasing observations spanning one second',
      () {
    final machine = AlertStateMachine();

    var output = danger(machine, candidate('boat/a', 0, 'fix-1'));
    expect(output.phaseFor('boat/a'), AlertPhase.candidate);

    output = danger(machine, candidate('boat/a', 1, 'fix-1'));
    expect(output.phaseFor('boat/a'), AlertPhase.candidate);

    output = danger(machine, candidate('boat/a', 1, 'fix-2'));
    expect(output.phaseFor('boat/a'), AlertPhase.alerting);
  });

  test('current overlap and deadline of two seconds start immediately', () {
    final overlapMachine = AlertStateMachine();
    final overlap = danger(
      overlapMachine,
      candidate('overlap', 0, 'fix-1', overlap: true),
    );
    expect(overlap.phaseFor('overlap'), AlertPhase.alerting);

    final deadlineMachine = AlertStateMachine();
    final deadline = danger(
      deadlineMachine,
      candidate(
        'deadline',
        0,
        'fix-1',
        deadline: const Duration(seconds: 2),
      ),
    );
    expect(deadline.phaseFor('deadline'), AlertPhase.alerting);
  });

  test('all alert categories clear after two seconds with normal quality', () {
    final machine = AlertStateMachine();
    danger(
      machine,
      candidate('boat/a', 0, 'danger', overlap: true),
    );

    var output = safety(machine, clear('boat/a', 1, 'clear-1'));
    expect(output.phaseFor('boat/a'), AlertPhase.clearing);
    expect(output.activeAlerts, hasLength(1));

    output = safety(machine, clear('boat/a', 2, 'clear-2'));
    expect(output.phaseFor('boat/a'), AlertPhase.clearing);

    output = safety(machine, clear('boat/a', 3, 'clear-3'));
    expect(output.phaseFor('boat/a'), AlertPhase.safe);
    expect(output.activeAlerts, isEmpty);
    expect(
      output.transitions.single.to,
      AlertPhase.safe,
    );
  });

  test('other boat also uses the default two-second clear policy', () {
    final machine = AlertStateMachine();
    danger(
      machine,
      candidate(
        'boat/good',
        0,
        'danger',
        overlap: true,
        category: 'other_boat',
      ),
    );

    var output = safety(machine, clear('boat/good', 1, 'clear-1'));
    expect(output.phaseFor('boat/good'), AlertPhase.clearing);

    output = safety(machine, clear('boat/good', 2, 'clear-2'));
    expect(output.phaseFor('boat/good'), AlertPhase.clearing);

    output = safety(machine, clear('boat/good', 3, 'clear-3'));
    expect(output.phaseFor('boat/good'), AlertPhase.safe);
  });

  test('degraded quality extends clearing to three seconds', () {
    final machine = AlertStateMachine();
    danger(
      machine,
      candidate(
        'boat/degraded',
        0,
        'danger',
        overlap: true,
        category: 'other_boat',
      ),
    );

    safety(
      machine,
      clear(
        'boat/degraded',
        1,
        'clear-1',
        quality: AlertDataQuality.degraded,
      ),
    );
    var output = safety(
      machine,
      clear(
        'boat/degraded',
        2,
        'clear-2',
        quality: AlertDataQuality.degraded,
      ),
    );
    expect(output.phaseFor('boat/degraded'), AlertPhase.clearing);

    output = safety(
      machine,
      clear(
        'boat/degraded',
        3,
        'clear-3',
        quality: AlertDataQuality.degraded,
      ),
    );
    expect(output.phaseFor('boat/degraded'), AlertPhase.clearing);

    output = safety(
      machine,
      clear(
        'boat/degraded',
        4,
        'clear-4',
        quality: AlertDataQuality.degraded,
      ),
    );
    expect(output.phaseFor('boat/degraded'), AlertPhase.safe);
  });

  test('quality changes keep progress and use the worst quality seen', () {
    final machine = AlertStateMachine();
    danger(
      machine,
      candidate(
        'boat/quality-change',
        0,
        'danger',
        overlap: true,
        category: 'other_boat',
      ),
    );

    safety(machine, clear('boat/quality-change', 1, 'good-1'));
    var output = safety(
      machine,
      clear(
        'boat/quality-change',
        2,
        'degraded-1',
        quality: AlertDataQuality.degraded,
      ),
    );
    expect(output.phaseFor('boat/quality-change'), AlertPhase.clearing);
    expect(output.alerts.single.confirmationObservationCount, 2);

    output = safety(
      machine,
      clear(
        'boat/quality-change',
        3,
        'good-2',
      ),
    );
    expect(output.phaseFor('boat/quality-change'), AlertPhase.clearing);
    expect(output.alerts.single.confirmationObservationCount, 3);

    output = safety(
      machine,
      clear(
        'boat/quality-change',
        4,
        'good-3',
      ),
    );
    expect(output.phaseFor('boat/quality-change'), AlertPhase.safe);
  });

  test('duplicate observation id does not accelerate other boat clearing', () {
    final machine = AlertStateMachine();
    danger(
      machine,
      candidate(
        'boat/duplicate',
        0,
        'danger',
        overlap: true,
        category: 'other_boat',
      ),
    );

    safety(machine, clear('boat/duplicate', 1, 'same-fix'));
    var output = safety(machine, clear('boat/duplicate', 2, 'same-fix'));
    expect(output.phaseFor('boat/duplicate'), AlertPhase.clearing);
    expect(output.alerts.single.confirmationObservationCount, 1);

    output = safety(machine, clear('boat/duplicate', 3, 'new-fix'));
    expect(output.phaseFor('boat/duplicate'), AlertPhase.safe);
  });

  test('danger during clearing returns to alerting without becoming safe', () {
    final machine = AlertStateMachine();
    danger(
      machine,
      candidate('boat/a', 0, 'danger-1', overlap: true),
    );
    safety(machine, clear('boat/a', 1, 'clear-1'));

    final output = danger(
      machine,
      candidate('boat/a', 2, 'danger-2'),
    );
    expect(output.phaseFor('boat/a'), AlertPhase.alerting);
    expect(output.activeAlerts, hasLength(1));
  });

  test('unusable interval preserves progress and finishes at three seconds',
      () {
    final machine = AlertStateMachine();
    danger(
      machine,
      candidate('boat/a', 0, 'danger', overlap: true),
    );
    safety(machine, clear('boat/a', 1, 'clear-1'));

    var output = machine.process(AlertEvaluationBatch(
      evaluatedAt: origin.add(const Duration(seconds: 2)),
    ));
    expect(output.phaseFor('boat/a'), AlertPhase.clearing);
    expect(output.alerts.single.dataUnknown, isTrue);

    output = safety(
      machine,
      clear(
        'boat/a',
        3,
        'gps-unusable',
        quality: AlertDataQuality.unusable,
      ),
    );
    expect(output.phaseFor('boat/a'), AlertPhase.clearing);
    expect(output.activeAlerts, hasLength(1));

    expect(output.alerts.single.confirmationObservationCount, 1);

    output = safety(
      machine,
      clear(
        'boat/a',
        4,
        'gps-unusable-2',
        quality: AlertDataQuality.unusable,
      ),
    );
    expect(output.phaseFor('boat/a'), AlertPhase.safe);
  });

  test('multiple candidates are retained and primary is deterministic', () {
    final machine = AlertStateMachine();
    final output = machine.process(AlertEvaluationBatch(
      evaluatedAt: origin,
      candidates: [
        candidate(
          'late',
          0,
          'fix-1',
          deadline: const Duration(seconds: 2),
        ),
        candidate('overlap', 0, 'fix-1', overlap: true),
      ],
    ));

    expect(output.activeAlerts, hasLength(2));
    expect(output.primaryAlert?.candidate.alertId, 'overlap');
  });

  test('comparator result is invariant across all candidate permutations', () {
    const comparator = AlertCandidateComparator();
    final values = [
      candidate('z', 0, '1', deadline: const Duration(seconds: 5)),
      candidate('a', 0, '1', deadline: const Duration(seconds: 5)),
      candidate(
        'fault',
        0,
        '1',
        deadline: null,
        behavior: AlertBehavior.persistentSystemFault,
        quality: AlertDataQuality.unusable,
      ),
    ];
    final permutations = <List<AlertCandidate>>[
      [values[0], values[1], values[2]],
      [values[0], values[2], values[1]],
      [values[1], values[0], values[2]],
      [values[1], values[2], values[0]],
      [values[2], values[0], values[1]],
      [values[2], values[1], values[0]],
    ];

    for (final permutation in permutations) {
      expect(
        comparator.ordered(permutation).map((value) => value.alertId),
        ['a', 'z', 'fault'],
      );
    }
  });

  test('primary lock holds within two seconds but urgent challenger preempts',
      () {
    const comparator = AlertCandidateComparator();
    final current = candidate(
      'current',
      0,
      'fix',
      deadline: const Duration(seconds: 6),
    );

    expect(
      comparator.selectPrimary(
        [
          current,
          candidate(
            'challenger',
            0,
            'fix',
            deadline: const Duration(seconds: 4),
          ),
        ],
        currentPrimaryAlertId: 'current',
      )?.alertId,
      'current',
    );
    expect(
      comparator.selectPrimary(
        [
          current,
          candidate(
            'urgent',
            0,
            'fix',
            deadline: const Duration(seconds: 3),
          ),
        ],
        currentPrimaryAlertId: 'current',
      )?.alertId,
      'urgent',
    );
  });

  test('橋と橋脚が重なると橋脚を優先し、橋のprimary lockも割り込む', () {
    const comparator = AlertCandidateComparator();
    final bridge = candidate(
      'bridge/main',
      0,
      'fix',
      overlap: true,
      category: 'bridge',
    );
    final pier = candidate(
      'bridgePier/p1',
      0,
      'fix',
      overlap: true,
      category: 'bridgePier',
    );

    expect(comparator.ordered([bridge, pier]).first.alertId, 'bridgePier/p1');
    expect(
      comparator.selectPrimary(
        [bridge, pier],
        currentPrimaryAlertId: bridge.alertId,
      )?.alertId,
      'bridgePier/p1',
    );
  });

  test('反復、単発、異常、案内、表示のみの順で音声対象を調停する', () {
    const comparator = AlertCandidateComparator();
    final ordered = comparator.ordered([
      candidate(
        'visual',
        0,
        'fix',
        behavior: AlertBehavior.visualOnly,
      ),
      candidate(
        'entry',
        0,
        'fix',
        behavior: AlertBehavior.entryEvent,
      ),
      candidate(
        'fault',
        0,
        'fix',
        behavior: AlertBehavior.persistentSystemFault,
      ),
      candidate(
        'single',
        0,
        'fix',
        behavior: AlertBehavior.singleAction,
      ),
      candidate('loop', 0, 'fix'),
    ]);

    expect(
      ordered.map((candidate) => candidate.alertId),
      ['loop', 'single', 'fault', 'entry', 'visual'],
    );
  });

  test('逆走注意はprimary lock中のカーブを即時割込みする', () {
    final machine = AlertStateMachine();
    var output = danger(
      machine,
      candidate(
        'curve',
        0,
        'fix-1',
        overlap: true,
        category: 'curve',
        internalPriority: 1,
      ),
    );
    expect(output.primaryAlert?.candidate.category, 'curve');

    output = machine.process(AlertEvaluationBatch(
      evaluatedAt: origin.add(const Duration(seconds: 1)),
      candidates: [
        candidate(
          'curve',
          1,
          'fix-2',
          overlap: true,
          category: 'curve',
          internalPriority: 1,
        ),
        candidate(
          'reverse',
          1,
          'fix-2',
          overlap: true,
          category: 'reverse',
          internalPriority: 1,
        ),
      ],
    ));

    expect(output.primaryAlert?.candidate.category, 'reverse');
    expect(output.activeAlerts, hasLength(2));
  });
}
