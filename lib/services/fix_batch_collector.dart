/// 同一イベントループで届いたfixを時刻順に確定する小さなバッファ。
///
/// 安全評価は最新の現在位置だけを処理する。途中のfixも[FixBatch.superseded]
/// として呼び出し側へ返すので、診断ログから情報を消さない。
class FixBatch<T> {
  final T latest;
  final List<T> superseded;

  const FixBatch({required this.latest, required this.superseded});
}

class FixBatchCollector<T> {
  final DateTime Function(T value) timestampOf;
  final List<T> _pending = [];

  FixBatchCollector(this.timestampOf);

  bool get isEmpty => _pending.isEmpty;

  void add(T value) => _pending.add(value);

  FixBatch<T>? takeBatch() {
    if (_pending.isEmpty) return null;
    final values = List<T>.of(_pending)
      ..sort((a, b) => timestampOf(a).compareTo(timestampOf(b)));
    _pending.clear();
    return FixBatch(
      latest: values.last,
      superseded: List<T>.unmodifiable(values.sublist(0, values.length - 1)),
    );
  }

  void clear() => _pending.clear();
}
