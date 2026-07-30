/// チーム共有の固定障害物校正を、単一文書listenerで同期する方針。
///
/// 監視・航行中だけ1本を接続し、障害物ごとのlistenerや一定間隔pollingは
/// 作らない。変更がない間は追加document readを発生させず、短時間に
/// 複数revisionが届いた場合は最新だけを適用する。
class SharedCalibrationSyncPolicy {
  static const coalesceWindow = Duration(seconds: 5);

  bool _listenerAttached = false;
  int? _lastAppliedRevision;
  int? _pendingRevision;

  bool get listenerAttached => _listenerAttached;
  int? get lastAppliedRevision => _lastAppliedRevision;
  int? get pendingRevision => _pendingRevision;

  /// 重複listenerを作らないため、実際の購読直前に呼ぶ。
  bool beginListening() {
    if (_listenerAttached) return false;
    _listenerAttached = true;
    return true;
  }

  void endListening() {
    _listenerAttached = false;
    _pendingRevision = null;
  }

  /// 未適用のうち最大revisionだけを残す。
  bool observeRevision(int revision) {
    if (revision < 0) {
      throw ArgumentError.value(revision, 'revision');
    }
    final applied = _lastAppliedRevision;
    final pending = _pendingRevision;
    if ((applied != null && revision <= applied) ||
        (pending != null && revision <= pending)) {
      return false;
    }
    _pendingRevision = revision;
    return true;
  }

  /// coalesce期限に、適用対象を1件だけ取り出す。
  int? takePendingRevision() {
    final revision = _pendingRevision;
    _pendingRevision = null;
    return revision;
  }

  void markApplied(int revision) {
    if (revision < 0) {
      throw ArgumentError.value(revision, 'revision');
    }
    if (_lastAppliedRevision == null || revision > _lastAppliedRevision!) {
      _lastAppliedRevision = revision;
    }
  }
}
