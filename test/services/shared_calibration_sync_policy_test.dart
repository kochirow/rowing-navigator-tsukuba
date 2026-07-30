import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/shared_calibration_sync_policy.dart';

void main() {
  group('SharedCalibrationSyncPolicy', () {
    test('購読は監視と航行で共用する1本だけ', () {
      final policy = SharedCalibrationSyncPolicy();
      expect(policy.beginListening(), isTrue);
      expect(policy.beginListening(), isFalse);
      expect(policy.listenerAttached, isTrue);
      policy.endListening();
      expect(policy.listenerAttached, isFalse);
      expect(policy.beginListening(), isTrue);
    });

    test('5秒coalesce中は最大revisionだけを適用する', () {
      final policy = SharedCalibrationSyncPolicy();
      expect(SharedCalibrationSyncPolicy.coalesceWindow,
          const Duration(seconds: 5));
      expect(policy.observeRevision(2), isTrue);
      expect(policy.observeRevision(2), isFalse);
      expect(policy.observeRevision(1), isFalse);
      expect(policy.observeRevision(4), isTrue);
      expect(policy.takePendingRevision(), 4);
      expect(policy.takePendingRevision(), isNull);
      policy.markApplied(4);
      expect(policy.observeRevision(3), isFalse);
      expect(policy.observeRevision(5), isTrue);
    });

    test('不正revisionを拒否し、購読停止時に保留を破棄する', () {
      final policy = SharedCalibrationSyncPolicy();
      expect(() => policy.observeRevision(-1), throwsArgumentError);
      policy.observeRevision(1);
      policy.endListening();
      expect(policy.pendingRevision, isNull);
    });
  });
}
