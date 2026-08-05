import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/navigator_config.dart';
import 'package:rowing_navigator/services/gps_health_monitor.dart';

/// 測位ポーリングと、その周辺のしきい値の関係を固定する。
///
/// 2026-08-05 の実機ログ2台(iPhone15,4 / iPhone17,5)で分かったこと。
///
/// - 測位間隔の中央値は 2003ms / 2000ms で、**端末をまたいで一致**していた。
/// - stream の無通知に対する `getCurrentPosition` は **541回すべて成功**し、
///   得られた測位は 42〜64ms前の新しいもの(所要 2〜4ms)。
///
/// つまり OS は測位を持っていて配信だけ絞る。**待つ時間を延ばすのではなく、
/// こちらから取りに行く。** 一度「休憩中は無通知の判定を15秒へ延ばす」を
/// 入れたが、それは確実に取れる測位を捨てる方向で、実測から欠測が
/// 21〜33%増える見積りだった。撤回済み。
void main() {
  test('推測航法で埋める前に、まず本物の測位を取りに行く', () {
    expect(
      gpsPositionPollAfterSilence,
      lessThanOrEqualTo(gpsDeadReckoningStartAfter),
      reason: '推測航法より後にポーリングすると、埋められる穴を予測で埋めてしまう',
    );
  });

  test('ポーリングは購読の張り直しより先に走る', () {
    expect(
      gpsPositionPollAfterSilence,
      lessThan(const Duration(seconds: gpsStreamSilenceRecoverySeconds)),
      reason: '再購読を待ってから取りに行くと、8秒の穴がそのまま残る',
    );
  });

  test('ポーリング間隔は安全評価の周期より速くしない', () {
    // 1秒周期の評価が消化できる以上に取っても意味がない。
    expect(
      gpsPositionPollMinimumInterval,
      greaterThanOrEqualTo(const Duration(seconds: 1)),
    );
  });

  test('ポーリングの上限時間は1秒ウォッチドッグを詰まらせない範囲に収める', () {
    // 実測 2〜4ms。これを大きく超えるのは異常なので、短く切り上げる。
    expect(gpsPositionPollTimeout, lessThanOrEqualTo(const Duration(seconds: 5)));
    expect(gpsPositionPollTimeout, greaterThan(gpsPositionPollMinimumInterval));
  });

  test('ポーリングを入れてもGPS途絶の確定は遅くならない', () {
    // `gps_unavailable` の確定はポーリングと独立。データ欠損を隠さない(原則6)。
    // ポーリングが成功すれば「本当に取れている」ので unusable にならないが、
    // 失敗し続ければ従来どおりの時刻で確定する。
    final unusableAfter = GpsHealthMonitor().unusableAfter;
    expect(gpsPositionPollAfterSilence, lessThan(unusableAfter));
  });

  test('無通知での再購読は「購読が死んだ」検知として残す', () {
    // ポーリングは配信の間引きへの対処で、購読そのものの死には効かない。
    // 8秒の再購読は残し、GPS途絶の確定(10秒)より前に始める。
    expect(
      const Duration(seconds: gpsStreamSilenceRecoverySeconds),
      lessThan(GpsHealthMonitor().unusableAfter),
    );
  });
}
