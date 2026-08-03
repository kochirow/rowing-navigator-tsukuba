import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/navigator_config.dart';
import 'package:rowing_navigator/services/gps_health_monitor.dart';

void main() {
  test('unusable回復確認中の受理fixはdegradedで安全判定へ通す', () {
    expect(
      evaluationQualityForAcceptedFix(GpsHealthQuality.unusable),
      GpsHealthQuality.degraded,
    );
    expect(
      evaluationQualityForAcceptedFix(GpsHealthQuality.good),
      GpsHealthQuality.good,
    );
  });

  final t0 = DateTime.utc(2026, 7, 15, 12);

  test('単発棄却はdegradedに留め、正常受理で戻る', () {
    final monitor = GpsHealthMonitor()..reset(acceptedAt: t0);
    expect(
      monitor.recordRejected(t0.add(const Duration(seconds: 1))).quality,
      GpsHealthQuality.degraded,
    );
    expect(
      monitor.recordAccepted(t0.add(const Duration(seconds: 2))).quality,
      GpsHealthQuality.good,
    );
  });

  test('低精度fixは受理しながらdegradedを維持する', () {
    final monitor = GpsHealthMonitor()..reset(acceptedAt: t0, degraded: true);
    expect(monitor.snapshot(t0).quality, GpsHealthQuality.degraded);
    expect(
      monitor
          .recordAccepted(
            t0.add(const Duration(seconds: 1)),
            degraded: true,
          )
          .quality,
      GpsHealthQuality.degraded,
    );
    expect(
      monitor.recordAccepted(t0.add(const Duration(seconds: 2))).quality,
      GpsHealthQuality.good,
    );
  });

  test('3連続棄却でunusableにする', () {
    final monitor = GpsHealthMonitor()..reset(acceptedAt: t0);
    monitor.recordRejected(t0.add(const Duration(seconds: 1)));
    monitor.recordRejected(t0.add(const Duration(seconds: 2)));
    expect(
      monitor.recordRejected(t0.add(const Duration(seconds: 3))).quality,
      GpsHealthQuality.unusable,
    );
  });

  test('3秒でdegraded、10秒でunusableにする', () {
    final monitor = GpsHealthMonitor()..reset(acceptedAt: t0);
    expect(
      monitor.tick(t0.add(const Duration(seconds: 3))).quality,
      GpsHealthQuality.degraded,
    );
    expect(
      monitor.tick(t0.add(const Duration(seconds: 10))).quality,
      GpsHealthQuality.unusable,
    );
  });

  test('unusableからの復帰は3観測かつ2秒を必要とする', () {
    final monitor = GpsHealthMonitor()..reset(acceptedAt: t0);
    monitor.tick(t0.add(const Duration(seconds: 10)));
    expect(
      monitor.recordAccepted(t0.add(const Duration(seconds: 11))).quality,
      GpsHealthQuality.unusable,
    );
    expect(
      monitor.recordAccepted(t0.add(const Duration(seconds: 12))).quality,
      GpsHealthQuality.unusable,
    );
    expect(
      monitor.recordAccepted(t0.add(const Duration(seconds: 13))).quality,
      GpsHealthQuality.good,
    );
  });

  test('stream例外は直ちにunusableへ遷移する', () {
    final monitor = GpsHealthMonitor();
    final now = DateTime.utc(2026, 7, 15, 12);
    monitor.reset(acceptedAt: now);
    expect(
      monitor.markUnusable(now.add(const Duration(seconds: 1))).quality,
      GpsHealthQuality.unusable,
    );
  });

  test('wall clockが戻ってもfilter通過済み測位を棄却扱いにしない', () {
    final monitor = GpsHealthMonitor()..reset(acceptedAt: t0);
    final result =
        monitor.recordAccepted(t0.subtract(const Duration(minutes: 1)));
    expect(result.quality, GpsHealthQuality.good);
    expect(result.consecutiveRejected, 0);
  });

  test('測位streamはunusable判定より先に再接続を始める', () {
    final monitor = GpsHealthMonitor();
    expect(
      gpsStreamSilenceRecoverySeconds,
      lessThan(monitor.unusableAfter.inSeconds),
    );
    expect(gpsStreamSilenceRecoverySeconds, 8);
  });
}
