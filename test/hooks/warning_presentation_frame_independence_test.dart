import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/safety_snapshot.dart';
import 'package:rowing_navigator/services/warning_presenter.dart';

/// 警告音の提示が**フレーム描画に依存しない**ことを機械的に固定する。
///
/// 2026-08-05 の実機ログ2台で、安全判定が「鳴らせ」を出した回数と、
/// 実際に再生要求へ届いた回数は 96→1 と 152→0 だった。ハートビートは
/// ほぼ全件 `paused`。原因は提示層が `useEffect`(= build の一部)にあり、
/// iOS がバックグラウンドでフレームを回さないため実行されなかったこと。
///
/// ここでは2つを固定する。
///
/// 1. **フレームが無ければ `useEffect` は走らない**(障害の再現)。
/// 2. 判定側から直接呼ぶ経路はフレーム無しでも届く(対策の証明)。
///
/// さらに、`use_navigator.dart` の配線が将来 `useEffect` へ戻されないよう、
/// ソース側の不変条件も検査する。
void main() {
  group('提示はフレームに依存しない', () {
    testWidgets('pumpを呼ばなければ useEffect は走らないが、直接呼び出しは届く', (tester) async {
      final directive = ValueNotifier<AudioDirective?>(null);
      addTearDown(directive.dispose);

      final viaEffect = <String>[];
      final viaDirectCall = <String>[];

      final presenter = WarningPresenter(
        onPlayLoop: (asset) => viaDirectCall.add('loop:$asset'),
        onPlayOnce: (asset, eventId) => viaDirectCall.add('once:$asset'),
        onStop: () => viaDirectCall.add('stop'),
        onDiagnostic: (_, __) {},
      );

      // 旧実装と同じ形。build の一部として走る経路。
      Widget build() => HookBuilder(builder: (context) {
            final current = useValueListenable(directive);
            useEffect(() {
              if (current != null) viaEffect.add('effect:${current.asset}');
              return null;
            }, [current?.alertId, current?.eventId]);
            return const SizedBox.shrink();
          });

      await tester.pumpWidget(MaterialApp(home: build()));
      expect(viaEffect, isEmpty);
      expect(viaDirectCall, isEmpty);

      // ここから先、**一度も pump しない**。実機のバックグラウンドと同じ状態。
      const next = AudioDirective(
        alertId: 'relative_boat_collision/other_boat/t:boat-2/-',
        asset: 'audio/other_boat_warning.mp3',
        mode: AudioDirectiveMode.loop,
        eventId: 'event-1',
      );
      directive.value = next;
      presenter.apply(next, ashore: false);

      expect(
        viaEffect,
        isEmpty,
        reason: 'フレームが無ければ useEffect は走らない。これが2026-08-05の障害',
      );
      expect(
        viaDirectCall,
        ['loop:audio/other_boat_warning.mp3'],
        reason: '直接呼び出しはフレーム無しでも届かなければならない',
      );

      // 参考: pump すれば旧経路も走る。つまり前景でだけ動いていた。
      await tester.pump();
      expect(viaEffect, ['effect:audio/other_boat_warning.mp3']);
    });

    test('use_navigator の提示は build 経路から呼ばれていない', () {
      // ソース側の不変条件。配線が `useEffect` へ戻れば落ちる。
      final source =
          File('lib/hooks/use_navigator.dart').readAsStringSync();

      // 提示は安全評価の適用(タイマー/ストリーム駆動)から直接呼ぶ。
      expect(
        source.contains('warningPresenter.value.apply('),
        isTrue,
        reason: '提示層の呼び出しが見つからない',
      );

      // `useEffect` の中で音声層を直接叩いていないこと。
      final effectBodies = RegExp(
        r'useEffect\(\(\) \{(.*?)\n  \}, ',
        dotAll: true,
      ).allMatches(source).map((match) => match.group(1) ?? '').toList();

      // **空振りで緑にならないこと。** 書式が変わって1つも拾えなくなったら、
      // 下のループは何も検査しない。拾えた数と実際の数を一致させておく。
      expect(
        effectBodies,
        hasLength(RegExp(r'useEffect\(\(\) \{').allMatches(source).length),
        reason: 'useEffect を全部拾えていない。この検査が空振りしている',
      );
      expect(effectBodies, isNotEmpty);

      for (final body in effectBodies) {
        expect(
          body.contains('alert.play(') ||
              body.contains('alert.playOnce(') ||
              body.contains('alert.playCue('),
          isFalse,
          reason: '再生要求が useEffect の中にある。背面でフレームが止まると実行されない',
        );
      }
    });
  });
}
