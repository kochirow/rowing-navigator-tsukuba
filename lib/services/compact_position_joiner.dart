import '../models/message_model.dart';

/// RTDBの差分位置と、1回だけ配信される艇profileを結合する。
/// position/profileの初回到着順に依存しない純粋Dart状態機械。
class CompactPositionJoiner {
  final Map<String, Map<Object?, Object?>> _pendingPositions = {};
  final Map<String, Map<Object?, Object?>> _profiles = {};

  Iterable<String> get pendingBoatIds =>
      List<String>.unmodifiable(_pendingPositions.keys);

  void putPosition(String boatId, Map<Object?, Object?> compact) {
    _pendingPositions[boatId] = compact;
  }

  void putProfile(String boatId, Map<Object?, Object?> profile) {
    _profiles[boatId] = profile;
  }

  Map<Object?, Object?>? takeExpanded(String boatId) {
    final compact = _pendingPositions[boatId];
    final profile = _profiles[boatId];
    if (compact == null || profile == null) return null;
    _pendingPositions.remove(boatId);
    return Message.expandCompactRtdbJson(
      boatId: boatId,
      compact: compact,
      profile: profile,
    );
  }

  void removePosition(String boatId) => _pendingPositions.remove(boatId);

  void removeProfile(String boatId) => _profiles.remove(boatId);
}
