import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/alert_candidate.dart';
import 'package:rowing_navigator/models/safety_snapshot.dart';
import 'package:rowing_navigator/services/presentation_state_codec.dart';

SafetySnapshot snapshotFor({
  required AlertBehavior behavior,
  required String category,
  AudioDirectiveMode? audioMode,
  SafetyRunMode runMode = SafetyRunMode.runningFull,
}) {
  final candidate = AlertCandidate(
    alertId: 'alert',
    detectorId: 'test',
    category: category,
    behavior: behavior,
    evaluatedAt: DateTime.utc(2026),
    observationId: 'observation',
  );
  return SafetySnapshot(
    sessionId: 'session',
    sessionGeneration: 0,
    revision: 1,
    evaluatedAt: DateTime.utc(2026),
    runMode: runMode,
    capabilities: const CapabilitySnapshot(
      gpsUsable: true,
      staticProfileUsable: true,
      audioUsable: true,
    ),
    activeAlerts: [
      ActiveAlert(candidate: candidate, phase: AlertPhase.alerting),
    ],
    health: const DetectorHealthSnapshot.empty(),
    primaryAlertId: 'alert',
    audioDirective: audioMode == null
        ? null
        : AudioDirective(alertId: 'alert', asset: 'asset', mode: audioMode),
    visualDirective: VisualDirective(['alert']),
  );
}

void main() {
  test('バンドは実際の鳴り方から作る', () {
    expect(
        PresentationStateCodec.warningFor(snapshotFor(
          behavior: AlertBehavior.continuousAction,
          category: 'other_boat',
          audioMode: AudioDirectiveMode.loop,
        )),
        '2o');
    expect(
        PresentationStateCodec.warningFor(snapshotFor(
          behavior: AlertBehavior.singleAction,
          category: 'bridge',
          audioMode: AudioDirectiveMode.playOnce,
        )),
        '1b');
    expect(
        PresentationStateCodec.warningFor(snapshotFor(
          behavior: AlertBehavior.visualOnly,
          category: 'shore',
        )),
        '0s');
  });

  test('system faultは表示のみとして記録する', () {
    expect(
        PresentationStateCodec.warningFor(snapshotFor(
          behavior: AlertBehavior.persistentSystemFault,
          category: 'gps_unavailable',
        )),
        '0f');
  });

  test('音声チャンネルを取れなかった候補は表示のみとして残す', () {
    // カーブ・逆走は衝突警告が鳴っている間は無音になる。
    // 鳴っていないものを「鳴った」と記録しない。
    final snapshot = snapshotFor(
      behavior: AlertBehavior.entryEvent,
      category: 'curve',
    );
    expect(PresentationStateCodec.warningFor(snapshot), '0c');
  });

  test('杭は圧縮した提示状態でも杭カテゴリを保持する', () {
    expect(
      PresentationStateCodec.warningFor(snapshotFor(
        behavior: AlertBehavior.continuousAction,
        category: 'pile',
        audioMode: AudioDirectiveMode.loop,
      )),
      '2k',
    );
  });

  test('警告なしは省略し、run modeを1文字にする', () {
    final noAlert = SafetySnapshot(
      sessionId: 'session',
      sessionGeneration: 0,
      revision: 1,
      evaluatedAt: DateTime.utc(2026),
      runMode: SafetyRunMode.runningDegraded,
      capabilities: const CapabilitySnapshot(
          gpsUsable: true, staticProfileUsable: true, audioUsable: true),
      activeAlerts: const [],
      health: const DetectorHealthSnapshot.empty(),
      visualDirective: const VisualDirective.empty(),
    );
    expect(PresentationStateCodec.warningFor(noAlert), isNull);
    expect(PresentationStateCodec.runModeFor(noAlert), 'd');
  });
}
