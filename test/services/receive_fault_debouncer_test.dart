import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/risk_evaluator_config.dart';
import 'package:rowing_navigator/config/system_fault_config.dart';
import 'package:rowing_navigator/services/receive_fault_debouncer.dart';

void main() {
  final t0 = DateTime.utc(2026, 7, 26, 12, 0, 0);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

  test('劣化が14秒では確定せず、15秒で確定する', () {
    final debouncer = ReceiveFaultDebouncer();

    expect(debouncer.update(degradedNow: true, at: at(0)), isFalse);
    expect(debouncer.update(degradedNow: true, at: at(14)), isFalse);
    expect(debouncer.isFaulted, isFalse);
    expect(debouncer.update(degradedNow: true, at: at(15)), isTrue);
    expect(debouncer.isFaulted, isTrue);
  });

  test('確定後、回復が14秒では解除されず、15秒で解除される', () {
    final debouncer = ReceiveFaultDebouncer();
    debouncer.update(degradedNow: true, at: at(0));
    debouncer.update(degradedNow: true, at: at(15));
    expect(debouncer.isFaulted, isTrue);

    expect(debouncer.update(degradedNow: false, at: at(20)), isTrue);
    expect(debouncer.update(degradedNow: false, at: at(34)), isTrue);
    expect(debouncer.update(degradedNow: false, at: at(35)), isFalse);
    expect(debouncer.isFaulted, isFalse);
  });

  test('劣化が途切れると確定までの計測はやり直しになる', () {
    final debouncer = ReceiveFaultDebouncer();

    for (var second = 0; second <= 14; second++) {
      expect(debouncer.update(degradedNow: true, at: at(second)), isFalse);
    }
    // 1回でも受信できたら計測をやり直す。
    expect(debouncer.update(degradedNow: false, at: at(15)), isFalse);
    expect(debouncer.update(degradedNow: true, at: at(16)), isFalse);
    // やり直し前の14秒を足しても確定しない。
    expect(debouncer.update(degradedNow: true, at: at(30)), isFalse);
    expect(debouncer.update(degradedNow: true, at: at(31)), isTrue);
  });

  test('実機ログのフラップ列(数秒周期の劣化と回復)ではfaultにならない', () {
    // 2026-07-26 実機ログ: other_boat_receive_unavailable が77分で315エピソード。
    // 4秒劣化 → 2秒回復 → 5秒劣化 → 2秒回復 … を繰り返しても確定させない。
    final debouncer = ReceiveFaultDebouncer();
    var second = 0;
    const pattern = [4, 5, 3, 6, 4];
    for (var cycle = 0; cycle < 12; cycle++) {
      final degradedSeconds = pattern[cycle % pattern.length];
      for (var i = 0; i < degradedSeconds; i++) {
        expect(
          debouncer.update(degradedNow: true, at: at(second)),
          isFalse,
          reason: 'cycle=$cycle t=${second}s で誤って確定した',
        );
        second++;
      }
      for (var i = 0; i < 2; i++) {
        expect(debouncer.update(degradedNow: false, at: at(second)), isFalse);
        second++;
      }
    }
    expect(debouncer.isFaulted, isFalse);
  });

  test('確定後のフラップでは解除されない(両側ヒステリシス)', () {
    final debouncer = ReceiveFaultDebouncer();
    debouncer.update(degradedNow: true, at: at(0));
    debouncer.update(degradedNow: true, at: at(15));
    expect(debouncer.isFaulted, isTrue);

    var second = 20;
    for (var cycle = 0; cycle < 10; cycle++) {
      for (var i = 0; i < 5; i++) {
        expect(debouncer.update(degradedNow: false, at: at(second)), isTrue);
        second++;
      }
      for (var i = 0; i < 2; i++) {
        expect(debouncer.update(degradedNow: true, at: at(second)), isTrue);
        second++;
      }
    }
    expect(debouncer.isFaulted, isTrue);
  });

  test('reset()で初期化される', () {
    final debouncer = ReceiveFaultDebouncer();
    debouncer.update(degradedNow: true, at: at(0));
    debouncer.update(degradedNow: true, at: at(15));
    expect(debouncer.isFaulted, isTrue);

    debouncer.reset();
    expect(debouncer.isFaulted, isFalse);
    // 計測中だった継続時間も消えていること。
    expect(debouncer.update(degradedNow: true, at: at(20)), isFalse);
    expect(debouncer.update(degradedNow: true, at: at(34)), isFalse);
    expect(debouncer.update(degradedNow: true, at: at(35)), isTrue);
  });

  test('時刻が巻き戻っても即座に確定しない', () {
    final debouncer = ReceiveFaultDebouncer();
    expect(debouncer.update(degradedNow: true, at: at(100)), isFalse);
    // 端末時計の補正で過去へ戻った場合、基点を引き直す。
    expect(debouncer.update(degradedNow: true, at: at(10)), isFalse);
    expect(debouncer.update(degradedNow: true, at: at(24)), isFalse);
    expect(debouncer.update(degradedNow: true, at: at(25)), isTrue);
  });

  test('確定・解除の遅延は鮮度階層の上限(30秒)を超えない', () {
    // CLAUDE.md 不変条件2。デバウンスが幽霊艇の消滅より遅れてはいけない。
    expect(dynamicReceiveFaultConfirmSec, lessThan(boatStaleTimeoutSeconds));
    expect(dynamicReceiveFaultClearSec, lessThan(boatStaleTimeoutSeconds));
  });

  test('注入した継続時間を使う', () {
    final debouncer = ReceiveFaultDebouncer(
      confirmDuration: const Duration(seconds: 3),
      clearDuration: const Duration(seconds: 2),
    );

    expect(debouncer.update(degradedNow: true, at: at(0)), isFalse);
    expect(debouncer.update(degradedNow: true, at: at(3)), isTrue);
    expect(debouncer.update(degradedNow: false, at: at(4)), isTrue);
    expect(debouncer.update(degradedNow: false, at: at(6)), isFalse);
  });
}
