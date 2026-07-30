enum GpsHealthQuality { good, degraded, unusable }

class GpsHealthSnapshot {
  final GpsHealthQuality quality;
  final DateTime? lastAcceptedAt;
  final Duration? acceptedAge;
  final int consecutiveRejected;
  final int recoveryAcceptedCount;

  const GpsHealthSnapshot({
    required this.quality,
    required this.lastAcceptedAt,
    required this.acceptedAge,
    required this.consecutiveRejected,
    required this.recoveryAcceptedCount,
  });
}

/// GPSの単発ノイズと本当の途絶を分ける軽量な状態管理。
/// unusableからは3観測かつ2秒を満たすまで復帰させない。
class GpsHealthMonitor {
  final Duration degradedAfter;
  final Duration unusableAfter;
  final int unusableAfterConsecutiveRejects;
  final int recoveryObservations;
  final Duration recoveryDuration;

  DateTime? _lastAcceptedAt;
  int _consecutiveRejected = 0;
  int _recoveryAcceptedCount = 0;
  DateTime? _recoveryStartedAt;
  GpsHealthQuality _quality = GpsHealthQuality.unusable;

  GpsHealthMonitor({
    this.degradedAfter = const Duration(seconds: 3),
    this.unusableAfter = const Duration(seconds: 10),
    this.unusableAfterConsecutiveRejects = 3,
    this.recoveryObservations = 3,
    this.recoveryDuration = const Duration(seconds: 2),
  });

  void reset({DateTime? acceptedAt, bool degraded = false}) {
    _lastAcceptedAt = acceptedAt;
    _consecutiveRejected = 0;
    _recoveryAcceptedCount = 0;
    _recoveryStartedAt = null;
    _quality = acceptedAt == null
        ? GpsHealthQuality.unusable
        : degraded
            ? GpsHealthQuality.degraded
            : GpsHealthQuality.good;
  }

  GpsHealthSnapshot recordAccepted(DateTime at, {bool degraded = false}) {
    // GPS filterを通った測位は受信側の単調時刻で順序確認済み。
    // OSのwall clockが戻ったことだけを理由に測位を連続棄却しない。
    if (_recoveryStartedAt != null && at.isBefore(_recoveryStartedAt!)) {
      _recoveryStartedAt = null;
      _recoveryAcceptedCount = 0;
    }
    _lastAcceptedAt = at;
    _consecutiveRejected = 0;
    if (_quality == GpsHealthQuality.unusable) {
      _recoveryStartedAt ??= at;
      _recoveryAcceptedCount += 1;
      if (_recoveryAcceptedCount >= recoveryObservations &&
          at.difference(_recoveryStartedAt!) >= recoveryDuration) {
        _quality = degraded ? GpsHealthQuality.degraded : GpsHealthQuality.good;
        _recoveryAcceptedCount = 0;
        _recoveryStartedAt = null;
      }
    } else {
      _quality = degraded ? GpsHealthQuality.degraded : GpsHealthQuality.good;
      _recoveryAcceptedCount = 0;
      _recoveryStartedAt = null;
    }
    return snapshot(at);
  }

  GpsHealthSnapshot recordRejected(DateTime at) {
    _consecutiveRejected += 1;
    _recoveryAcceptedCount = 0;
    _recoveryStartedAt = null;
    final age = _age(at);
    if (_lastAcceptedAt == null ||
        (age != null && age >= unusableAfter) ||
        _consecutiveRejected >= unusableAfterConsecutiveRejects) {
      _quality = GpsHealthQuality.unusable;
    } else {
      _quality = GpsHealthQuality.degraded;
    }
    return snapshot(at);
  }

  GpsHealthSnapshot markUnusable(DateTime at) {
    _quality = GpsHealthQuality.unusable;
    _consecutiveRejected = unusableAfterConsecutiveRejects;
    _recoveryAcceptedCount = 0;
    _recoveryStartedAt = null;
    return snapshot(at);
  }

  GpsHealthSnapshot tick(DateTime now) {
    final age = _age(now);
    if (_lastAcceptedAt == null || (age != null && age >= unusableAfter)) {
      _quality = GpsHealthQuality.unusable;
      _recoveryAcceptedCount = 0;
      _recoveryStartedAt = null;
    } else if (age != null &&
        age >= degradedAfter &&
        _quality == GpsHealthQuality.good) {
      _quality = GpsHealthQuality.degraded;
    }
    return snapshot(now);
  }

  GpsHealthSnapshot snapshot(DateTime now) => GpsHealthSnapshot(
        quality: _quality,
        lastAcceptedAt: _lastAcceptedAt,
        acceptedAge: _age(now),
        consecutiveRejected: _consecutiveRejected,
        recoveryAcceptedCount: _recoveryAcceptedCount,
      );

  Duration? _age(DateTime now) {
    final acceptedAt = _lastAcceptedAt;
    if (acceptedAt == null) return null;
    final age = now.difference(acceptedAt);
    return age.isNegative ? Duration.zero : age;
  }
}
