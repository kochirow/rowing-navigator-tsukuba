import '../config/risk_evaluator_config.dart';

/// 逆走の発報を継続時間で確定させる、解除0秒の非対称デバウンサ。
///
/// Timer は持たない。評価時刻を受け取るため、1Hz以外の評価周期でも同じ
/// 意味を保ち、単体テストでも時刻を正確に進められる。
class ReverseGuidanceDebouncer {
  ReverseGuidanceDebouncer({Duration? confirmDuration})
      : _confirmDuration = confirmDuration ??
            Duration(
              milliseconds: (reverseGuidanceConfirmSeconds * 1000).round(),
            );

  final Duration _confirmDuration;
  DateTime? _reverseSince;
  bool _confirmed = false;

  /// [isReverse] が確認時間継続したときだけ `true` を返す。
  ///
  /// 逆走でなくなった時点で即座に状態を消す。端末時計が巻き戻った場合は
  /// 基点を引き直し、過去時刻を使って誤って確定しない。
  bool update({required bool isReverse, required DateTime at}) {
    if (!isReverse) {
      reset();
      return false;
    }
    final since = _reverseSince;
    if (since == null || at.isBefore(since)) {
      _reverseSince = at;
      _confirmed = _confirmDuration == Duration.zero;
      return _confirmed;
    }
    if (at.difference(since) >= _confirmDuration) {
      _confirmed = true;
    }
    return _confirmed;
  }

  void reset() {
    _reverseSince = null;
    _confirmed = false;
  }
}
