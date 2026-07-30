enum TrackingMode {
  /// 自艇位置へ自動追従する通常状態。
  track,

  /// ジェスチャーで地図を動かしたため一時的に追従を止めた状態。
  /// 一定時間後にだけ自動追従へ戻す。
  untrackedByGesture,

  /// 利用者が追跡ボタンで明示的に解除した状態。
  /// 自動的には追従へ戻さない。
  untrackedByUser,
}

extension TrackingModeX on TrackingMode {
  bool get isTracking => this == TrackingMode.track;

  bool get allowsAutomaticRecentering =>
      this == TrackingMode.untrackedByGesture;
}
