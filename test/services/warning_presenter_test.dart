import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/safety_snapshot.dart';
import 'package:rowing_navigator/services/warning_presenter.dart';

/// 2026-08-05 の実機ログ(2時間13分)で、安全判定が96回「鳴らせ」を出したのに
/// 再生要求が1回しか出なかった障害への対策を固定する。
///
/// 原因は提示層が `useEffect`(= build の一部)に置かれていたこと。
/// iOS はアプリが `paused` の間フレームを回さないため、判定は動き続けたが
/// 音へ変える1段だけが実行されなかった。
void main() {
  late List<String> commands;
  late List<String> diagnostics;
  late WarningPresenter presenter;

  setUp(() {
    commands = <String>[];
    diagnostics = <String>[];
    presenter = WarningPresenter(
      onPlayLoop: (asset) => commands.add('loop:$asset'),
      onPlayOnce: (asset, eventId) => commands.add('once:$asset:$eventId'),
      onStop: () => commands.add('stop'),
      onDiagnostic: (type, details) =>
          diagnostics.add('$type:${details['reason'] ?? details['eventId']}'),
    );
  });

  AudioDirective directive({
    String alertId = 'static_collision/shore/v:shore_north/-',
    String asset = 'audio/shore_warning.mp3',
    AudioDirectiveMode mode = AudioDirectiveMode.loop,
    String? eventId = 'event-1',
  }) =>
      AudioDirective(
        alertId: alertId,
        asset: asset,
        mode: mode,
        eventId: eventId,
      );

  test('ループ指示で再生要求を1回だけ出す', () {
    expect(presenter.apply(directive(), ashore: false), isTrue);
    expect(commands, ['loop:audio/shore_warning.mp3']);
    expect(diagnostics, contains('warning_presentation_requested:event-1'));
  });

  test('同じ指示が何度来ても再生要求は増えない', () {
    // 判定は1秒ごとに走る。呼び出し頻度に依存しない冪等性が要る。
    expect(presenter.apply(directive(), ashore: false), isTrue);
    for (var i = 1; i < 10; i++) {
      expect(presenter.apply(directive(), ashore: false), isFalse);
    }
    expect(commands, ['loop:audio/shore_warning.mp3']);
  });

  test('eventIdが変われば鳴らし直す', () {
    expect(
        presenter.apply(
          directive(mode: AudioDirectiveMode.playOnce, eventId: 'event-1'),
          ashore: false,
        ),
        isTrue);
    expect(
        presenter.apply(
          directive(mode: AudioDirectiveMode.playOnce, eventId: 'event-2'),
          ashore: false,
        ),
        isTrue);
    expect(commands, [
      'once:audio/shore_warning.mp3:event-1',
      'once:audio/shore_warning.mp3:event-2',
    ]);
  });

  test('指示が消えたら1回だけ止め、その後は止め続けない', () {
    presenter.apply(directive(), ashore: false);
    commands.clear();
    presenter.apply(null, ashore: false);
    expect(commands, ['stop']);

    // 止まっている状態で毎秒 stop を投げると直列キューが空の停止で埋まる。
    for (var i = 0; i < 5; i++) {
      presenter.apply(null, ashore: false);
    }
    expect(commands, ['stop']);
  });

  test('陸上判定中は鳴らさず、水上へ戻れば鳴り直す', () {
    expect(presenter.apply(directive(), ashore: true), isFalse);
    expect(commands, isEmpty, reason: '一度も鳴っていなければ停止も要らない');

    expect(presenter.apply(directive(), ashore: false), isTrue);
    expect(commands, ['loop:audio/shore_warning.mp3']);

    commands.clear();
    expect(presenter.apply(directive(), ashore: true), isFalse);
    expect(commands, ['stop']);
    expect(diagnostics, contains('warning_presentation_cleared:ashore'));
  });

  test('eventIdが無い指示はalertIdを重複排除キーにする', () {
    expect(
        presenter.apply(
          directive(mode: AudioDirectiveMode.playOnce, eventId: null),
          ashore: false,
        ),
        isTrue);
    expect(
        presenter.apply(
          directive(mode: AudioDirectiveMode.playOnce, eventId: null),
          ashore: false,
        ),
        isFalse);
    expect(commands, [
      'once:audio/shore_warning.mp3:static_collision/shore/v:shore_north/-',
    ]);
  });

  test('resetは提示していなくても確実に止める', () {
    presenter.reset();
    expect(commands, ['stop']);
  });

  test('別の警告へ切り替わったら新しい方を鳴らす', () {
    presenter.apply(directive(), ashore: false);
    expect(
        presenter.apply(
          directive(
            alertId: 'relative_boat_collision/other_boat/t:boat-2/-',
            asset: 'audio/other_boat_warning.mp3',
            eventId: 'event-9',
          ),
          ashore: false,
        ),
        isTrue);
    expect(commands, [
      'loop:audio/shore_warning.mp3',
      'loop:audio/other_boat_warning.mp3',
    ]);
  });
}
