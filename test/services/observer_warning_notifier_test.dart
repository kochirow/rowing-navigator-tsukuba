import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/observer_warning_notifier.dart';

void main() {
  final t0 = DateTime.utc(2026, 10, 30, 6);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));
  ObserverWarningInput input(String boatId, String? w, int seconds) =>
      ObserverWarningInput(
        boatId: boatId,
        presentationState: w,
        observedAt: at(seconds),
      );

  /// 毎秒、同じ状態の新しいメッセージが届く想定で回し、バイブの回数を数える。
  List<ObserverWarningVibration> run(
    ObserverWarningNotifier notifier,
    List<String?> statesPerSecond, {
    String boatId = 'a',
    int startAt = 0,
    bool deliver = true,
  }) {
    final vibrations = <ObserverWarningVibration>[];
    for (var i = 0; i < statesPerSecond.length; i++) {
      final s = startAt + i;
      final update = notifier.update(
        inputs: [input(boatId, statesPerSecond[i], s)],
        now: at(s),
        deliver: deliver,
      );
      if (update.vibration != null) vibrations.add(update.vibration!);
    }
    return vibrations;
  }

  test('音なしから音ありに変わったときに1回、続く間は繰り返さない', () {
    final notifier = ObserverWarningNotifier();
    final vibrations = run(notifier, [null, '0o', '2o', '2o', '2o', '2o']);
    expect(vibrations, hasLength(1));
    expect(vibrations.single.band, ObserverWarningBand.continuous);
    expect(vibrations.single.warnings.single.categoryCode, 'o');
  });

  test('表示のみ(band 0)と system fault は通知しない', () {
    final notifier = ObserverWarningNotifier();
    expect(run(notifier, ['0o', '0s', '1f', '2f', '0f']), isEmpty);
  });

  test('音ありのまま種類が変わったら、もう1回(2秒あけて)', () {
    final notifier = ObserverWarningNotifier();
    final vibrations = run(notifier, ['1s', '1s', '1s', '2o', '2o']);
    expect(vibrations, hasLength(2));
    expect(vibrations.last.warnings.single.categoryCode, 'o');
  });

  test('帯が変わるだけ(単発→連続音)では鳴らし直さない', () {
    final notifier = ObserverWarningNotifier();
    expect(run(notifier, ['1o', '2o', '2o', '1o']), hasLength(1));
  });

  test('逆走の「5秒あけて2回」の合間では鳴らし直さず、10秒の無音の後に再武装する', () {
    final notifier = ObserverWarningNotifier();
    final states = <String?>[
      '1r', '1r', null, null, null, null, null, '1r', '1r', // 5秒の合間
      null, null, null, null, null, null, null, null, null, null, null, // 11秒
      '1r',
    ];
    final vibrations = run(notifier, states);
    expect(vibrations, hasLength(2));
    expect(vibrations.last.at, at(20));
  });

  test('10秒より古いメッセージは音なしとして扱う', () {
    final notifier = ObserverWarningNotifier();
    final update = notifier.update(
      inputs: [input('a', '2o', 0)],
      now: at(11),
      deliver: true,
    );
    expect(update.vibration, isNull);
    expect(update.active, isEmpty);
  });

  test('複数の艇が同時に変わっても2秒に1回へまとめる', () {
    final notifier = ObserverWarningNotifier();
    final first = notifier.update(
      inputs: [input('a', '1s', 0), input('b', '2o', 0)],
      now: at(0),
      deliver: true,
    );
    expect(first.vibration!.warnings, hasLength(2));
    expect(first.vibration!.band, ObserverWarningBand.continuous);
    // 1秒後に別の艇が変わっても、まだ鳴らさない
    final second = notifier.update(
      inputs: [input('a', '1s', 1), input('b', '2o', 1), input('c', '1k', 1)],
      now: at(1),
      deliver: true,
    );
    expect(second.vibration, isNull);
    // 2秒経てば、まとめ待ちの分を鳴らす
    final third = notifier.update(
      inputs: [input('a', '1s', 2), input('b', '2o', 2), input('c', '1k', 2)],
      now: at(2),
      deliver: true,
    );
    expect(third.vibration!.warnings.single.boatId, 'c');
  });

  test('画面が前面にない間の変化は、復帰しても鳴らさない', () {
    final notifier = ObserverWarningNotifier();
    expect(run(notifier, [null, '2o', '2o'], deliver: false), isEmpty);
    // 復帰後も同じ警告が続いているだけなら鳴らさない
    expect(run(notifier, ['2o', '2o'], startAt: 3), isEmpty);
    // 復帰後に新しく変わったものは鳴らす
    expect(run(notifier, ['2k'], startAt: 5), hasLength(1));
  });

  test('継続時間の起点は種類が変わるまで保つ', () {
    final notifier = ObserverWarningNotifier();
    run(notifier, ['1o', '2o', '2o']);
    final update = notifier.update(
      inputs: [input('a', '2o', 3)],
      now: at(3),
      deliver: true,
    );
    final warning = update.active['a']!;
    expect(warning.since, at(0));
    expect(warning.band, ObserverWarningBand.continuous);
    expect(warning.listLabel, '警告：他艇に注意（連続音）');
    expect(warning.categoryLabel, '他艇');
  });

  test('不正な値・古い版(w なし)は警告なしとして扱う', () {
    final notifier = ObserverWarningNotifier();
    expect(run(notifier, ['3o', '2z', 'xx', '']), isEmpty);
  });
}
