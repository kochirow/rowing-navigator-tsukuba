import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/sharing_capability_monitor.dart';

/// Stage 3 S3-11/12: 「0隻」ではなく能力を監視することを固定する。
///
/// 2026-08-06 実機ログ: 1台が2セッション118分にわたり
/// `positionSharingState = unavailable` のまま走り、他艇を1隻も
/// 受信しなかったが、ストリームのエラーは0件で何も表示されなかった。
void main() {
  final t0 = DateTime.utc(2026, 8, 6, 6);

  SharingCapability healthy({
    Duration? sinceLastRemoteUpdate,
  }) =>
      SharingCapability(
        publishSetupComplete: true,
        sinceLastPublishAck: const Duration(seconds: 1),
        subscriptionConnected: true,
        authorization: SharingAuthorization.granted,
        serverTimeOffsetAge: const Duration(seconds: 5),
        sinceLastRemoteUpdate: sinceLastRemoteUpdate,
        rosterAvailable: true,
      );

  group('能力の判定', () {
    test('他艇が0隻でも、能力が確認できていれば fault にしない', () {
      final monitor = SharingCapabilityMonitor();
      // 最初に出艇した艇。まだ誰も水上にいないので受信は0隻。
      final capability = healthy(sinceLastRemoteUpdate: null);
      expect(capability.isReceiveCapabilityConfirmed, isTrue);
      for (var minute = 0; minute <= 10; minute++) {
        expect(
          monitor.update(capability, at: t0.add(Duration(minutes: minute))),
          isFalse,
        );
      }
    });

    test('購読が繋がっていなければ、確認できていないと判定する', () {
      const capability = SharingCapability(
        publishSetupComplete: true,
        subscriptionConnected: false,
        authorization: SharingAuthorization.granted,
      );
      expect(capability.isReceiveCapabilityConfirmed, isFalse);
    });

    test('送信の初期設定が終わっていなければ、確認できていないと判定する', () {
      const capability = SharingCapability(
        publishSetupComplete: false,
        subscriptionConnected: true,
        authorization: SharingAuthorization.granted,
      );
      expect(capability.isPublishCapabilityConfirmed, isFalse);
    });
  });

  group('fault の確定', () {
    test('起動直後の数秒の未確立では fault にしない', () {
      final monitor = SharingCapabilityMonitor();
      const degraded = SharingCapability(
        publishSetupComplete: false,
        subscriptionConnected: false,
      );
      expect(monitor.update(degraded, at: t0), isFalse);
      expect(
        monitor.update(degraded, at: t0.add(const Duration(seconds: 10))),
        isFalse,
      );
    });

    test('未確立が確定時間を超えたら fault にする(118分の無自覚を防ぐ)', () {
      final monitor = SharingCapabilityMonitor();
      const degraded = SharingCapability(
        publishSetupComplete: false,
        subscriptionConnected: false,
      );
      monitor.update(degraded, at: t0);
      expect(
        monitor.update(degraded, at: t0.add(const Duration(seconds: 61))),
        isTrue,
      );
    });

    test('回復したら即座に解除する(非対称)', () {
      final monitor = SharingCapabilityMonitor();
      const degraded = SharingCapability();
      monitor.update(degraded, at: t0);
      expect(
        monitor.update(degraded, at: t0.add(const Duration(seconds: 61))),
        isTrue,
      );
      expect(
        monitor.update(healthy(), at: t0.add(const Duration(seconds: 62))),
        isFalse,
      );
    });

    test('permission-denied は待たずに即座に fault にする', () {
      final monitor = SharingCapabilityMonitor();
      const denied = SharingCapability(
        publishSetupComplete: true,
        subscriptionConnected: true,
        authorization: SharingAuthorization.denied,
      );
      // 再試行で直る種類ではないので、確定待ちの意味がない。
      expect(monitor.update(denied, at: t0), isTrue);
    });

    test('時刻が巻き戻っても即座に確定しない', () {
      final monitor = SharingCapabilityMonitor();
      const degraded = SharingCapability();
      monitor.update(degraded, at: t0.add(const Duration(seconds: 30)));
      expect(monitor.update(degraded, at: t0), isFalse);
    });
  });

  group('再試行の原因別分類', () {
    test('permission-denied は最大3回の失敗で打ち切る', () {
      final kind = classifySharingFailure(errorCode: 'permission-denied');
      expect(kind, SharingFailureKind.permissionDenied);
      expect(kind.isRetryable, isTrue);
      expect(kind.shouldRetry(1), isTrue);
      expect(kind.shouldRetry(2), isTrue);
      expect(kind.shouldRetry(3), isFalse);
      expect(kind.backoffFor(1), const Duration(seconds: 1));
    });

    test('データ契約の不一致は再試行しない', () {
      final kind = classifySharingFailure(errorCode: 'invalid-argument');
      expect(kind.isRetryable, isFalse);
    });

    test('タイムアウトは指数バックオフで再試行する', () {
      final kind = classifySharingFailure(errorType: 'TimeoutException');
      expect(kind, SharingFailureKind.transientTimeout);
      expect(kind.isRetryable, isTrue);
      expect(kind.backoffFor(1), const Duration(seconds: 1));
      expect(kind.backoffFor(2), const Duration(seconds: 2));
      expect(kind.backoffFor(3), const Duration(seconds: 4));
      // 上限で頭打ちにし、際限なく延びないようにする。
      expect(kind.backoffFor(10).inSeconds, lessThanOrEqualTo(60));
    });

    test('一時切断はまず即座に1回試す', () {
      final kind = classifySharingFailure(errorCode: 'disconnected');
      expect(kind, SharingFailureKind.transientDisconnect);
      expect(kind.backoffFor(1), Duration.zero);
      expect(kind.backoffFor(2), greaterThan(Duration.zero));
    });

    test('バックオフは試行回数に対して単調に増える', () {
      final kind = classifySharingFailure(errorType: 'TimeoutException');
      var previous = Duration.zero;
      for (var attempt = 1; attempt <= 8; attempt++) {
        final wait = kind.backoffFor(attempt);
        expect(wait, greaterThanOrEqualTo(previous));
        previous = wait;
      }
    });
  });
}
