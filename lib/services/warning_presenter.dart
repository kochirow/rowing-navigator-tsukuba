import '../models/safety_snapshot.dart';

/// 安全判定が決めた音声指示を、実際の再生要求へ変える層。
///
/// ## なぜウィジェットの外に置くか
///
/// **この処理はフレーム描画に依存してはいけない。**
///
/// 以前は `use_navigator.dart` の `useEffect` に置いていた。`useEffect` は
/// build の一部として走るため、iOS がアプリを `paused` にしてフレームを
/// 回さなくなると、`audioDirective` が更新されても本体が実行されない。
/// GPS・1秒周期の安全評価・記録・位置共有はタイマー駆動なので動き続け、
/// **判定結果を音へ変える1段だけ**が止まっていた。
///
/// 2026-08-05 の実機ログ(2時間13分)では、安全判定が96回「鳴らせ」を出した
/// のに再生要求は1回しか出ていない。ハートビート249回すべてで
/// `lifecycle` は `paused` だった。唯一鳴った1回は、利用者が桟橋で端末を
/// 手に取った直後である。
///
/// いまは `audioDirective` を設定した場所から直接 [apply] を呼ぶ。
/// build を経由しないので、背面でも同じ経路で鳴る。
///
/// ## 重複除去が必須である理由
///
/// listener/直接呼び出しは build より高い頻度で走る。同じ指示で
/// [apply] が何度呼ばれても、再生要求は1回しか出してはいけない。
/// 出すと `use_alert` の直列キューが同じ音の停止と再生を往復し、
/// 段階が上がる瞬間に古い要求が新しい音を止める。
///
/// ## 陸上判定
///
/// 陸上判定中は持続音を止める。検知・表示・記録・位置共有は続いており、
/// 水面側の測位を1点でも観測すれば即座に戻る(原則1)。
class WarningPresenter {
  /// ループ再生を要求する。
  final void Function(String asset) onPlayLoop;

  /// 単発再生を要求する。`eventId` は消費側の重複排除キー。
  final void Function(String asset, String eventId) onPlayOnce;

  /// 再生を止める。
  final void Function() onStop;

  /// 診断イベントを1件記録する。
  final void Function(String type, Map<String, dynamic> details) onDiagnostic;

  String? _presentedWarningKey;
  String? _presentedAsset;
  AudioDirectiveMode? _presentedMode;
  String? _presentedEventId;

  WarningPresenter({
    required this.onPlayLoop,
    required this.onPlayOnce,
    required this.onStop,
    required this.onDiagnostic,
  });

  /// いま提示中の警告キー。表示層の整合確認とテスト用。
  String? get presentedWarningKey => _presentedWarningKey;

  /// 音声指示を適用する。
  ///
  /// [directive] が null、または [ashore] が true なら停止する。
  /// [category] は診断ログ用で、判断には使わない。
  void apply(
    AudioDirective? directive, {
    required bool ashore,
    String? category,
  }) {
    if (directive == null || ashore) {
      _clear(reason: ashore ? 'ashore' : 'no_audio_directive');
      return;
    }

    final eventId = directive.eventId ?? directive.alertId;
    // 直前とまったく同じ指示なら何もしない。呼び出し頻度に依存しない
    // 冪等性を、この1点で保証する。
    if (_presentedWarningKey == directive.alertId &&
        _presentedAsset == directive.asset &&
        _presentedMode == directive.mode &&
        _presentedEventId == eventId) {
      return;
    }

    _presentedWarningKey = directive.alertId;
    _presentedAsset = directive.asset;
    _presentedMode = directive.mode;
    _presentedEventId = eventId;

    onDiagnostic('warning_presentation_requested', {
      'warningKey': directive.alertId,
      'category': category,
      'asset': directive.asset,
      'mode': directive.mode.name,
      'eventId': eventId,
    });

    switch (directive.mode) {
      case AudioDirectiveMode.loop:
        onPlayLoop(directive.asset);
        break;
      case AudioDirectiveMode.playOnce:
        onPlayOnce(directive.asset, eventId);
        break;
    }
  }

  /// 航行終了などで、指示の有無に関係なく確実に止める。
  void reset() => _clear(reason: 'navigation_stopped', force: true);

  void _clear({required String reason, bool force = false}) {
    final previous = _presentedWarningKey;
    _presentedWarningKey = null;
    _presentedAsset = null;
    _presentedMode = null;
    _presentedEventId = null;
    if (previous != null) {
      onDiagnostic('warning_presentation_cleared', {
        'previousWarningKey': previous,
        'reason': reason,
      });
    }
    // **止まっている状態で毎秒 stop を投げない。** [apply] は1秒ごとの
    // 安全評価から呼ばれるので、無条件に停止要求を出すと直列キューが
    // 空の停止で埋まる。鳴っていた指示が消えた瞬間だけ止める。
    // OSの割り込みからの復帰は `use_alert` の watchdog が担当する。
    if (previous != null || force) onStop();
  }
}
