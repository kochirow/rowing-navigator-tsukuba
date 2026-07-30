import '../config/system_fault_config.dart';

/// 瞬間的な能力劣化を system fault へ昇格させないためのデバウンサ。
///
/// 「劣化が confirm 秒続いたら fault」「回復が clear 秒続いたら解除」の
/// 両側にヒステリシスを持たせる。片側だけだとフラップは止まらない。
///
/// 受信劣化(両側15秒)のほか、GPS途絶・評価停止の能力欠如
/// (確定10秒・解除0秒の非対称)にも使う。
/// clear を 0 にすると回復した時点で即座に解除する。
///
/// ## これは「データ欠損を安全の根拠にする」ものではない
///
/// DESIGN_PRINCIPLES 原則6(データ欠損は安全の根拠にならない)に抵触しない。
/// 遅らせるのは **fault の提示(音とバナー)だけ** である。
/// 他艇トラックの鮮度管理には一切触れない:
///
/// - `OtherBoatTrackStore.freshUntil`(3秒)
/// - `boatPredictionTimeoutSeconds`(6秒)
/// - `boatStaleTimeoutSeconds`(30秒)
///
/// これらは従来どおり即時に効き、受信が途絶えれば他艇は予測TTLを過ぎた
/// 時点で評価から外れ、幽霊艇は30秒で消える。デバウンサが遅らせるのは
/// 「受信できていないと利用者へ告げる」タイミングだけで、
/// 衝突判定の入力を古いまま延命させることはしない。
/// CLAUDE.md の不変条件2「鮮度の階層」を壊さないこと。
///
/// ## 遅延量が鮮度階層を超えないこと
///
/// 確定・解除の遅延はそれぞれ最大 [dynamicReceiveFaultConfirmSec] /
/// [dynamicReceiveFaultClearSec] = 15秒であり、鮮度階層の上限である
/// `boatStaleTimeoutSeconds`(30秒)を下回る。したがって
/// 「幽霊艇が消えるより後に fault が出る」逆転は起きない。
/// 設定値を変えるときはこの不等式を必ず維持すること。
class ReceiveFaultDebouncer {
  ReceiveFaultDebouncer({
    Duration? confirmDuration,
    Duration? clearDuration,
  })  : _confirmDuration = confirmDuration ??
            const Duration(seconds: dynamicReceiveFaultConfirmSec),
        _clearDuration = clearDuration ??
            const Duration(seconds: dynamicReceiveFaultClearSec);

  final Duration _confirmDuration;
  final Duration _clearDuration;

  bool _faulted = false;

  /// 現在の状態と逆の条件が続き始めた時刻。条件が途切れたら null に戻す。
  /// 非 fault 中は「劣化が始まった時刻」、fault 中は「回復が始まった時刻」。
  DateTime? _pendingSince;

  /// 現在 fault とみなしているか。
  bool get isFaulted => _faulted;

  /// [degradedNow] を反映し、現在 fault とみなすべきかを返す。
  ///
  /// [at] は呼出側が持つ現在時刻。単体テストで時間を進められるよう注入する。
  /// 時刻が巻き戻った場合(端末時計の補正など)は、経過時間を負として
  /// 扱わず基点を [at] へ引き直す。巻き戻りで即座に確定・解除しない。
  bool update({required bool degradedNow, required DateTime at}) {
    // 目指している遷移先。fault 中は「解除」、非 fault 中は「確定」。
    final wantsTransition = _faulted ? !degradedNow : degradedNow;
    if (!wantsTransition) {
      // 条件が途切れたので継続時間の計測をやり直す。
      _pendingSince = null;
      return _faulted;
    }
    final since = _pendingSince;
    if (since == null || at.isBefore(since)) {
      _pendingSince = at;
    }
    // 継続時間 0 の側は、基点を置いたその場で遷移させる。次のtickまで
    // 待つと1Hz評価では約1秒遅れ、「即座に解除」が成立しない。
    // 正の継続時間では従来と同じ(基点を置いた回は必ず false になる)。
    final required = _faulted ? _clearDuration : _confirmDuration;
    if (at.difference(_pendingSince!) >= required) {
      _faulted = !_faulted;
      _pendingSince = null;
    }
    return _faulted;
  }

  /// 初期状態(fault なし・計測中の継続時間なし)へ戻す。
  /// 航行の開始・停止や受信ストリームの張り直しで呼ぶ。
  void reset() {
    _faulted = false;
    _pendingSince = null;
  }
}
